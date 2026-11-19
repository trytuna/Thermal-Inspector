import Foundation

/// Which camera to use.
enum CameraSource: String, CaseIterable, Identifiable, Sendable {
    case p3
    case p1
    case simulation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p3: "ThermalMaster P3"
        case .p1: "ThermalMaster P1"
        case .simulation: String(localized: "Demo (simulated board)")
        }
    }

    fileprivate func makeCamera() -> ThermalCamera {
        switch self {
        case .p3: P3Camera(model: .p3)
        case .p1: P3Camera(model: .p1)
        case .simulation: SimulatedCamera()
        }
    }
}

/// What the camera thread reports back to the app.
enum CameraEvent: Sendable {
    /// No camera plugged in – we keep looking.
    case searching
    /// Camera found, starting the stream (takes a few seconds).
    case connecting
    case streaming(CameraInfo)
    case frame(RawThermalFrame)
    /// Something went wrong; the controller retries automatically.
    case failure(String)
    /// Informational message, e.g. the result of a command.
    case message(String)
}

/// Runs a camera on a dedicated background thread.
///
/// USB reads block, so they get their own thread instead of a Swift task.
/// Results are delivered as an `AsyncStream` of `CameraEvent`s. If the camera
/// is unplugged or not yet connected, the controller retries every second –
/// plugging the camera in is all the user has to do.
final class CameraController: @unchecked Sendable {
    private let lock = NSLock()
    private var currentRun: Run?

    /// Starts streaming from `source`. Stops a previous run first.
    func start(source: CameraSource) -> AsyncStream<CameraEvent> {
        stop()

        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self, bufferingPolicy: .bufferingNewest(8))
        let run = Run()
        lock.withLock { currentRun = run }

        let thread = Thread {
            Self.runLoop(source: source, run: run, events: continuation)
        }
        thread.name = "Camera"
        thread.qualityOfService = .userInteractive
        thread.start()

        return stream
    }

    /// Stops the camera thread.
    ///
    /// - Parameter waitUntilClosed: block until the camera is closed (or `timeout`
    ///   passed). Use this before quitting: a camera that is left streaming can hang
    ///   and drop off the USB bus until it is replugged.
    func stop(waitUntilClosed: Bool = false, timeout: TimeInterval = 3) {
        let run = lock.withLock {
            defer { currentRun = nil }
            return currentRun
        }
        run?.cancel()
        if waitUntilClosed { run?.waitUntilFinished(timeout: timeout) }
    }

    /// Queues a command; it is executed on the camera thread between two frames.
    func send(_ command: CameraCommand) {
        lock.withLock { currentRun }?.enqueue(command)
    }

    // MARK: Camera thread

    private static func runLoop(source: CameraSource, run: Run, events: AsyncStream<CameraEvent>.Continuation) {
        defer {
            events.finish()
            run.markFinished()
        }

        while !run.isCancelled {
            let camera = source.makeCamera()
            do {
                events.yield(.connecting)
                let info = try camera.open()
                try camera.startStreaming()
                events.yield(.streaming(info))
                try streamFrames(from: camera, run: run, events: events)
                camera.close()
            } catch {
                camera.close()
                guard !run.isCancelled else { break }
                if case USBError.deviceNotFound = error {
                    events.yield(.searching)
                } else {
                    events.yield(.failure(error.localizedDescription))
                }
                run.sleep(seconds: 1)
            }
        }
    }

    /// Reads frames until the run is cancelled or the camera stops working.
    private static func streamFrames(from camera: ThermalCamera, run: Run,
                                     events: AsyncStream<CameraEvent>.Continuation) throws {
        var consecutiveErrors = 0

        while !run.isCancelled {
            for command in run.takeCommands() {
                do {
                    try camera.perform(command)
                } catch {
                    events.yield(.message(String(localized: "Command failed: \(error.localizedDescription)")))
                }
            }

            do {
                if let frame = try camera.readFrame() {
                    events.yield(.frame(frame))
                }
                consecutiveErrors = 0
            } catch {
                // Single read errors happen occasionally; many in a row mean the camera is gone.
                consecutiveErrors += 1
                if consecutiveErrors >= 5 { throw error }
            }
        }
    }

    /// State shared between the controller and one camera thread.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var commands: [CameraCommand] = []
        private let finished = DispatchSemaphore(value: 0)

        var isCancelled: Bool { lock.withLock { cancelled } }

        func markFinished() { finished.signal() }

        func waitUntilFinished(timeout: TimeInterval) {
            _ = finished.wait(timeout: .now() + timeout)
        }

        func cancel() { lock.withLock { cancelled = true } }

        func enqueue(_ command: CameraCommand) { lock.withLock { commands.append(command) } }

        func takeCommands() -> [CameraCommand] {
            lock.withLock {
                defer { commands.removeAll() }
                return commands
            }
        }

        /// Sleeps, but wakes up early when cancelled.
        func sleep(seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !isCancelled {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
