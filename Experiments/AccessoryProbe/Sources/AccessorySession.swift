import ExternalAccessory
import Foundation

/// Runs an External Accessory session on its own thread.
///
/// The session's input and output streams are scheduled on a private run loop.
/// Incoming bytes are parsed for P3 frames right here, so only finished frames
/// and statistics are passed to the main thread.
final class AccessorySession: NSObject, StreamDelegate {
    struct Statistics {
        var bytesReceived = 0
        var reads = 0
        var framesParsed = 0
        var skippedBytes = 0
        var bytesSent = 0
    }

    /// Called on the session thread. Dispatch to the main thread yourself.
    var onFrame: ((RawThermalFrame) -> Void)?
    var onStatistics: ((Statistics) -> Void)?
    var onLog: ((String) -> Void)?

    private let session: EASession
    private var thread: Thread?
    private var isCancelled = false

    // Only touched on the session thread:
    private var parser = P3StreamParser(model: .p3)
    private var statistics = Statistics()
    private var pendingWrites = Data()
    private var loggedChunks = 0
    private var readBuffer = [UInt8](repeating: 0, count: 65_536)

    init?(accessory: EAAccessory, protocolName: String) {
        guard let session = EASession(accessory: accessory, forProtocol: protocolName) else { return nil }
        self.session = session
    }

    func start() {
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "AccessorySession"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        isCancelled = true
    }

    /// Sends bytes to the accessory (queued and written when the stream has space).
    func send(_ data: Data) {
        guard let thread else { return }
        perform(#selector(enqueue(_:)), on: thread, with: data, waitUntilDone: false)
    }

    // MARK: Session thread

    private func runLoop() {
        guard let input = session.inputStream, let output = session.outputStream else {
            onLog?("Session has no streams")
            return
        }
        for stream in [input, output] as [Stream] {
            stream.delegate = self
            stream.schedule(in: .current, forMode: .default)
            stream.open()
        }
        onLog?("Streams opened")

        while !isCancelled {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        for stream in [input, output] as [Stream] {
            stream.close()
            stream.remove(from: .current, forMode: .default)
        }
        onLog?("Streams closed")
    }

    @objc private func enqueue(_ data: Data) {
        pendingWrites.append(data)
        flushWrites()
    }

    private func flushWrites() {
        guard let output = session.outputStream, output.hasSpaceAvailable, !pendingWrites.isEmpty else { return }
        let written = pendingWrites.withUnsafeBytes { bytes in
            output.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
        }
        if written > 0 {
            onLog?("Sent \(written) bytes: \(Self.hex(pendingWrites.prefix(written)))")
            statistics.bytesSent += written
            pendingWrites.removeFirst(written)
        } else if written < 0 {
            onLog?("Write failed: \(output.streamError?.localizedDescription ?? "unknown error")")
        }
    }

    private func readAvailableBytes(from input: InputStream) {
        while input.hasBytesAvailable {
            let count = input.read(&readBuffer, maxLength: readBuffer.count)
            guard count > 0 else { break }
            let chunk = readBuffer[0..<count]
            statistics.bytesReceived += count
            statistics.reads += 1

            let framesBefore = statistics.framesParsed
            for frame in parser.append(chunk) {
                statistics.framesParsed += 1
                onFrame?(frame)
            }
            statistics.skippedBytes = parser.skippedBytes

            // Log the first chunks and everything that does not belong to a frame,
            // so we can see what the camera sends (e.g. answers to commands).
            if loggedChunks < 40, statistics.framesParsed == framesBefore {
                loggedChunks += 1
                onLog?("Received \(count) bytes: \(Self.hex(chunk.prefix(48)))\(count > 48 ? " …" : "")")
            }
        }
        onStatistics?(statistics)
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            if let input = stream as? InputStream { readAvailableBytes(from: input) }
        case .hasSpaceAvailable:
            flushWrites()
        case .errorOccurred:
            onLog?("Stream error: \(stream.streamError?.localizedDescription ?? "unknown")")
        case .endEncountered:
            onLog?("Stream ended")
        case .openCompleted:
            onLog?("\(stream is InputStream ? "Input" : "Output") stream open")
        default:
            break
        }
    }

    static func hex(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
