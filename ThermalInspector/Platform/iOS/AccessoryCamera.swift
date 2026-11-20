import ExternalAccessory
import Foundation
import os

/// The P3 connected to an iPhone or iPad.
///
/// iOS treats the camera as an MFi accessory with the External Accessory protocol
/// `com.thermalmaster.pios3`. After opening a session we send the start packet
/// (`P3AccessoryProtocol`); the data contains the same frames as over USB on the
/// Mac, so `P3StreamParser` can decode it (see docs/HARDWARE-NOTES.md).
///
/// Shutter and gain commands are sent as `P3AccessoryProtocol` packets.
///
/// All methods run on the camera thread of `CameraController`. The input stream is
/// scheduled on that thread's run loop, which `readFrame()` keeps turning.
final class AccessoryCamera: NSObject, ThermalCamera, StreamDelegate {
    static let protocolName = "com.thermalmaster.pios3"

    let model = CameraModel.p3
    private let settings: CameraSettings
    /// Settings sent once the first image data has arrived (like the official app does).
    private var pendingSettings: [CameraCommand] = []

    init(settings: CameraSettings) {
        self.settings = settings
    }

    /// If no data arrives for this long, the camera is considered gone.
    private let dataTimeout: TimeInterval = 3
    /// After opening, the first data may take a little longer.
    private let startTimeout: TimeInterval = 8
    private var hasReceivedData = false

    private var session: EASession?
    private var parser = P3StreamParser(model: .p3)
    private var pendingFrames: [RawThermalFrame] = []
    private var streamFailure: Error?
    private var lastDataTime = Date()
    private var readBuffer = [UInt8](repeating: 0, count: 65_536)
    /// Bytes waiting until the output stream has space.
    private var pendingWrites: [UInt8] = []
    /// Sequence number of the last command packet (the header's first byte).
    private var commandSequence: UInt8 = 0

    /// Diagnostics, visible in Xcode's console or Console.app (category "Accessory").
    private let log = Logger(subsystem: "ThermalInspector", category: "Accessory")
    private var bytesReceived = 0
    private var framesParsed = 0
    private var lastLogTime = Date()

    func open() throws -> CameraInfo {
        // The External Accessory framework only keeps its list of connected accessories
        // up to date on the main thread – asked from the camera thread, it stays empty.
        // So the camera is looked up and the session opened on the main thread.
        let found: (session: EASession, info: CameraInfo)? = DispatchQueue.main.sync {
            guard let accessory = EAAccessoryManager.shared().connectedAccessories
                .first(where: { $0.protocolStrings.contains(Self.protocolName) }),
                let session = EASession(accessory: accessory, forProtocol: Self.protocolName) else {
                return nil
            }
            let info = CameraInfo(modelName: accessory.name, firmwareVersion: accessory.firmwareRevision,
                                  hardwareVersion: accessory.hardwareRevision, serialNumber: accessory.serialNumber,
                                  partNumber: accessory.modelNumber)
            return (session, info)
        }
        guard let found else { throw CameraError.notConnected }
        log.info("Session opened: \(found.info.modelName, privacy: .public)")
        session = found.session
        return found.info
    }

    func startStreaming() throws {
        guard let input = session?.inputStream, let output = session?.outputStream else {
            throw CameraError.notConnected
        }
        parser = P3StreamParser(model: model)
        pendingFrames.removeAll()
        streamFailure = nil
        hasReceivedData = false
        pendingWrites.removeAll()
        commandSequence = 0
        lastDataTime = Date()

        for stream in [input, output] as [Stream] {
            stream.delegate = self
            stream.schedule(in: .current, forMode: .default)
            stream.open()
        }
        log.info("Streams opened, status \(input.streamStatus.rawValue) / \(output.streamStatus.rawValue)")

        // Like the official app: first the automatic shutter setting, wait for the
        // camera's short answer, then start the stream. A freshly plugged-in camera
        // stops streaming again if it gets this setting after the start packet.
        writeCommand(P3AccessoryProtocol.automaticShutter(settings.automaticShutter))
        let deadline = Date().addingTimeInterval(1)
        while !hasReceivedData, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        // The answer is not image data – the start timeout begins now.
        hasReceivedData = false
        lastDataTime = Date()
        write(P3AccessoryProtocol.startStream)
        pendingSettings = settings.commands
    }

    func readFrame() throws -> RawThermalFrame? {
        if pendingFrames.isEmpty {
            // Let the run loop deliver stream events for a moment.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        if !hasReceivedData, Date().timeIntervalSince(lastLogTime) > 1, let input = session?.inputStream {
            lastLogTime = Date()
            log.info("Waiting for data: input status \(input.streamStatus.rawValue), bytes available \(input.hasBytesAvailable)")
        }
        if let streamFailure { throw streamFailure }
        if hasReceivedData, !pendingSettings.isEmpty {
            for command in pendingSettings { try perform(command) }
            pendingSettings.removeAll()
        }
        let timeout = hasReceivedData ? dataTimeout : startTimeout
        if Date().timeIntervalSince(lastDataTime) > timeout {
            // Sometimes the camera accepts the connection but never starts sending
            // (observed after earlier sessions); only replugging it helps then.
            throw hasReceivedData ? CameraError.notConnected : CameraError.noImageData
        }
        return pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
    }

    func perform(_ command: CameraCommand) throws {
        if case .triggerShutter = command {
            writeCommand(P3AccessoryProtocol.shutter)
        } else if let body = P3AccessoryProtocol.settingCommand(command) {
            writeCommand(body)
        }
    }

    /// Sends a 16-byte command with the next sequence number.
    private func writeCommand(_ command: [UInt8]) {
        commandSequence &+= 1
        write(P3AccessoryProtocol.packet(command: command, sequence: commandSequence, isFirst: commandSequence == 1))
    }

    func close() {
        guard let session else { return }
        // Stop the stream like the official app does, so the camera is idle for the next app.
        if let output = session.outputStream, output.streamStatus == .open {
            write(P3AccessoryProtocol.stopStream)
            let deadline = Date().addingTimeInterval(0.3)
            while !pendingWrites.isEmpty, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
        }
        for stream in [session.inputStream, session.outputStream].compactMap({ $0 }) as [Stream] {
            stream.close()
            stream.remove(from: .current, forMode: .default)
        }
        self.session = nil
    }

    /// Queues bytes for the camera; they are written as soon as the stream has space.
    private func write(_ bytes: [UInt8]) {
        pendingWrites += bytes
        flushWrites()
    }

    private func flushWrites() {
        guard let output = session?.outputStream, output.hasSpaceAvailable, !pendingWrites.isEmpty else { return }
        let written = output.write(pendingWrites, maxLength: pendingWrites.count)
        if written > 0 {
            log.info("Sent \(written) bytes: \(self.pendingWrites.prefix(written).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
            pendingWrites.removeFirst(written)
        } else if written < 0 {
            log.error("Write failed: \(output.streamError?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }

    private func logStatisticsNowAndThen() {
        guard Date().timeIntervalSince(lastLogTime) > 2 else { return }
        lastLogTime = Date()
        let counter = pendingFrames.last?.cameraFrameCounter.map(String.init) ?? "–"
        log.info("Received \(self.bytesReceived) bytes, \(self.framesParsed) frames, skipped \(self.parser.skippedBytes) bytes, frame counter \(counter, privacy: .public)")
    }

    // MARK: StreamDelegate

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            guard let input = stream as? InputStream else { return }
            while input.hasBytesAvailable {
                let count = input.read(&readBuffer, maxLength: readBuffer.count)
                guard count > 0 else { break }
                lastDataTime = Date()
                hasReceivedData = true
                bytesReceived += count
                let frames = parser.append(readBuffer[0..<count])
                framesParsed += frames.count
                pendingFrames += frames
            }
            // If the app falls behind, keep only the newest frames.
            if pendingFrames.count > 4 { pendingFrames.removeFirst(pendingFrames.count - 4) }
            logStatisticsNowAndThen()
        case .hasSpaceAvailable:
            flushWrites()
        case .errorOccurred:
            log.error("Stream error: \(stream.streamError?.localizedDescription ?? "unknown", privacy: .public)")
            streamFailure = stream.streamError ?? CameraError.notConnected
        case .endEncountered:
            // The camera was unplugged.
            streamFailure = CameraError.notConnected
        default:
            log.info("Stream event \(event.rawValue) on \(stream is InputStream ? "input" : "output", privacy: .public)")
        }
    }
}
