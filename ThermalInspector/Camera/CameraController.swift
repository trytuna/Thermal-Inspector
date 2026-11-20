import Foundation

/// Which camera to use. The available sources depend on the platform.
enum CameraSource: String, CaseIterable, Identifiable, Sendable {
    #if os(macOS)
    /// Connected by USB, driven directly (IOUSBHost).
    case p3
    case p1
    #else
    /// Connected to an iPhone/iPad, driven as an MFi accessory (External Accessory).
    case accessory
    #endif
    case simulation

    /// The camera used when nothing else was chosen.
    #if os(macOS)
    static let standard = CameraSource.p3
    #else
    static let standard = CameraSource.accessory
    #endif

    var id: String { rawValue }

    var label: String {
        switch self {
        #if os(macOS)
        case .p3: "ThermalMaster P3"
        case .p1: "ThermalMaster P1"
        #else
        case .accessory: "ThermalMaster P3"
        #endif
        case .simulation: String(localized: "Demo (simulated board)")
        }
    }

    fileprivate func makeCamera(settings: CameraSettings) -> ThermalCamera {
        switch self {
        #if os(macOS)
        case .p3: P3Camera(model: .p3, settings: settings)
        case .p1: P3Camera(model: .p1, settings: settings)
        #else
        case .accessory: AccessoryCamera(settings: settings)
        #endif
        case .simulation: SimulatedCamera(automaticCalibration: settings.automaticShutter)
        }
    }
}

/// Settings the camera gets while connecting (they cannot be changed while streaming).
struct CameraSettings: Sendable {
    /// Whether the camera recalibrates itself about every 90 s.
    var automaticShutter = true
    var burnProtection = true
    /// Image settings to apply; the camera keeps its own value for the others.
    var imageAdjustments: [ImageAdjustment: Int] = [:]

    /// The commands that apply these settings (except the automatic shutter, which
    /// has to be sent before the stream starts).
    var commands: [CameraCommand] {
        [.setBurnProtection(burnProtection)]
            + ImageAdjustment.allCases.compactMap { adjustment in
                imageAdjustments[adjustment].map { .setImageAdjustment(adjustment, $0) }
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
    func start(source: CameraSource, settings: CameraSettings = CameraSettings()) -> AsyncStream<CameraEvent> {
        stop()

        // Status events must never be lost, so the stream is unbounded. Frames cannot
        // pile up anyway: the camera thread only sends a new one when the app has
        // handled the previous ones (see `frameHandled()`).
        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self, bufferingPolicy: .unbounded)
        let run = Run()
        lock.withLock { currentRun = run }

        let thread = Thread {
            Self.runLoop(source: source, settings: settings, run: run, events: continuation)
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

    /// Call after a `.frame` event was processed. Until then, newer frames are skipped.
    func frameHandled() {
        lock.withLock { currentRun }?.frameHandled()
    }

    /// Queues a command; it is executed on the camera thread between two frames.
    func send(_ command: CameraCommand) {
        lock.withLock { currentRun }?.enqueue(command)
    }

    // MARK: Camera thread

    private static func runLoop(source: CameraSource, settings: CameraSettings, run: Run,
                                events: AsyncStream<CameraEvent>.Continuation) {
        defer {
            events.finish()
            run.markFinished()
        }

        // Looking for the camera happens quietly in the background: the app only hears
        // about it when something changes (camera found, a different error), so the
        // status does not flicker every second while nothing is plugged in.
        var lastStatus: Status?
        func report(_ status: Status) {
            guard status != lastStatus else { return }
            lastStatus = status
            events.yield(status.event)
        }

        while !run.isCancelled {
            let camera = source.makeCamera(settings: settings)
            do {
                let info = try camera.open()
                // Keep showing an error while retrying, instead of alternating with "Connecting".
                if lastStatus == nil || lastStatus == .searching { report(.connecting) }
                try camera.startStreaming()
                lastStatus = nil
                events.yield(.streaming(info))
                try streamFrames(from: camera, run: run, events: events)
                camera.close()
            } catch {
                camera.close()
                guard !run.isCancelled else { break }
                if case CameraError.notConnected = error {
                    report(.searching)
                } else {
                    report(.failure(error.localizedDescription))
                }
                run.sleep(seconds: 1)
            }
        }
    }

    /// The status events of the retry loop, comparable so repeats can be left out.
    private enum Status: Equatable {
        case searching
        case connecting
        case failure(String)

        var event: CameraEvent {
            switch self {
            case .searching: .searching
            case .connecting: .connecting
            case let .failure(message): .failure(message)
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
                // Skip frames while the app is still busy with earlier ones (keeps the image current).
                if let frame = try camera.readFrame(), run.reserveFrameSlot() {
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
        /// Frames sent to the app but not handled yet.
        private var framesInFlight = 0
        private let maximumFramesInFlight = 2

        var isCancelled: Bool { lock.withLock { cancelled } }

        func markFinished() { finished.signal() }

        func waitUntilFinished(timeout: TimeInterval) {
            _ = finished.wait(timeout: .now() + timeout)
        }

        func cancel() { lock.withLock { cancelled = true } }

        /// True (and counted) if another frame may be sent to the app.
        func reserveFrameSlot() -> Bool {
            lock.withLock {
                guard framesInFlight < maximumFramesInFlight else { return false }
                framesInFlight += 1
                return true
            }
        }

        func frameHandled() {
            lock.withLock { framesInFlight = max(framesInFlight - 1, 0) }
        }

        func enqueue(_ command: CameraCommand) {
            lock.withLock {
                // A slider sends many values – only the newest one per setting matters.
                if case let .setImageAdjustment(adjustment, _) = command {
                    commands.removeAll {
                        if case .setImageAdjustment(adjustment, _) = $0 { return true }
                        return false
                    }
                }
                commands.append(command)
            }
        }

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
