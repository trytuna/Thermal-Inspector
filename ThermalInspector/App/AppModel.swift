import Foundation
import Observation
import SwiftUI

extension Notification.Name {
    /// Posted when the app is about to quit, so the camera can be stopped cleanly.
    static let appWillQuit = Notification.Name("ThermalInspector.appWillQuit")
}

/// Connection status shown in the UI.
enum ConnectionState: Equatable {
    case idle
    case searching
    case connecting
    case streaming
    case failed(String)

    var description: String {
        switch self {
        case .idle: String(localized: "Disconnected")
        case .searching: String(localized: "Looking for camera … please connect it via USB")
        case .connecting: String(localized: "Connecting …")
        case .streaming: String(localized: "Live")
        case let .failed(message): String(localized: "Error: \(message)")
        }
    }

    var color: Color {
        switch self {
        case .streaming: .green
        case .connecting, .searching: .orange
        case .failed: .red
        case .idle: .gray
        }
    }
}

/// What the main image shows.
enum ImageMode: String, CaseIterable, Identifiable, Codable {
    /// Colors mapped from the measured temperatures.
    case temperature
    /// The camera's own detail-enhanced image – better to recognize component outlines.
    /// Measurements still use the temperatures.
    case detail

    var id: String { rawValue }
    var name: String { self == .temperature ? String(localized: "Temperature") : String(localized: "Detail") }
}

enum RangeMode: String, CaseIterable, Identifiable, Codable {
    case automatic
    case manual

    var id: String { rawValue }
    var name: String { self == .automatic ? String(localized: "Automatic") : String(localized: "Manual") }
}

/// The central state of the app: camera connection, image processing,
/// display settings, measurements, history and recording.
///
/// Processing pipeline for every camera frame:
///
///     raw frame → average N frames → °C (emissivity) → rotate/mirror
///               → (minus reference in difference mode) → color image
@MainActor
@Observable
final class AppModel {

    // MARK: - Camera

    /// Remembered between launches. Can be overridden with the launch argument `-cameraSource simulation`.
    var cameraSource = CameraSource(rawValue: UserDefaults.standard.string(forKey: "cameraSource") ?? "") ?? .standard {
        didSet {
            guard cameraSource != oldValue else { return }
            UserDefaults.standard.set(cameraSource.rawValue, forKey: "cameraSource")
            startCamera()
        }
    }
    private(set) var connectionState: ConnectionState = .idle
    private(set) var cameraInfo: CameraInfo?
    private(set) var framesPerSecond: Double = 0

    var gainMode: GainMode = .high {
        didSet { if gainMode != oldValue { cameraController.send(.setGain(gainMode)) } }
    }

    /// Whether the camera recalibrates itself about every 90 s (stored in the preferences).
    /// The camera only accepts this while connecting, so changing it reconnects (a few seconds).
    var automaticShutter: Bool {
        get { preferences.automaticShutter }
        set {
            guard newValue != preferences.automaticShutter else { return }
            preferences.automaticShutter = newValue
            startCamera()
        }
    }

    var burnProtection: Bool {
        get { preferences.burnProtection }
        set {
            preferences.burnProtection = newValue
            cameraController.send(.setBurnProtection(newValue))
        }
    }

    /// The value of an image setting, nil while the camera keeps its own value.
    func imageAdjustment(_ adjustment: ImageAdjustment) -> Int? {
        preferences.imageAdjustments[adjustment]
    }

    func setImageAdjustment(_ adjustment: ImageAdjustment, to value: Int) {
        // A slider reports the same rounded value many times while it moves.
        guard preferences.imageAdjustments[adjustment] != value else { return }
        preferences.imageAdjustments[adjustment] = value
        cameraController.send(.setImageAdjustment(adjustment, value))
    }

    /// Range of the temperature sliders (color range, isotherm) in the current gain mode.
    /// The low gain is specified for 100…600 °C, but the camera still reports colder
    /// parts of the scene, so the sliders start at −20 °C there as well.
    var sensorRange: ClosedRange<Float> { gainMode == .high ? -20...150 : -20...600 }

    // MARK: - Display settings

    var palette: Palette = .iron { didSet { updateDisplay() } }
    var imageMode: ImageMode = .temperature { didSet { updateDisplay() } }
    /// True when the detail image is shown (not available in difference mode).
    var isShowingDetail: Bool { imageMode == .detail && !isShowingDifference && latestDetail != nil }
    var rangeMode: RangeMode = .automatic { didSet { updateDisplay() } }
    var manualMinimum: Float = 20 { didSet { updateDisplay() } }
    var manualMaximum: Float = 60 { didSet { updateDisplay() } }
    var smoothInterpolation = true
    var showHotAndColdMarkers = true
    var orientation = ImageOrientation() {
        didSet { if orientation != oldValue { orientationChanged() } }
    }

    /// Isotherm: only pixels above the threshold are colored.
    var isothermEnabled = false { didSet { updateDisplay() } }
    var isothermThreshold: Float = 50 { didSet { updateDisplay() } }

    // MARK: - Measurement settings

    var radiometry = RadiometricSettings() { didSet { rebuildFrame() } }
    var averagedFrames = 4 { didSet { averager.frameCount = averagedFrames } }

    // MARK: - Difference mode (ΔT against a reference image)

    private(set) var referenceFrame: ThermalFrame?
    /// 0…1 while a reference is being captured, nil otherwise.
    private(set) var referenceCaptureProgress: Double?
    var showDifference = false { didSet { updateDisplay() } }
    var isShowingDifference: Bool { showDifference && referenceFrame != nil }
    /// The camera recalibrated after the reference was taken, so the difference image
    /// contains the calibration offset.
    private(set) var referenceIsOutdated = false

    // MARK: - Camera calibration (drift)

    /// Watches the camera's automatic recalibrations and how much they corrected.
    private(set) var calibration = CalibrationMonitor()

    // MARK: - Measurements

    var tool: MeasurementTool = .spot
    private(set) var spots: [SpotMeasurement] = []
    private(set) var boxes: [BoxMeasurement] = []
    /// Pixel under the mouse pointer.
    var hoverPoint: PixelPoint?

    // MARK: - Live image

    /// The current frame in °C, already rotated/mirrored.
    private(set) var absoluteFrame: ThermalFrame?
    /// The frame that is displayed: `absoluteFrame` or the difference to the reference.
    private(set) var displayFrame: ThermalFrame?
    private(set) var displayStatistics: TemperatureStatistics?
    private(set) var displayRange: ClosedRange<Float> = 20...40
    private(set) var image: CGImage?
    var isFrozen = false

    // MARK: - History and recording

    private(set) var history = TemperatureHistory()
    var historyWindow: TimeInterval = 60
    private(set) var videoRecorder: VideoRecorder?
    var isRecording: Bool { videoRecorder != nil }

    /// Short-lived message in the status bar.
    private(set) var statusMessage: String?
    private(set) var lastSavedURL: URL?

    // MARK: - Preferences

    let preferences = Preferences()

    // MARK: - Private state

    private let cameraController = CameraController()
    private var cameraTask: Task<Void, Never>?
    private var averager = FrameAverager()
    private var autoRange = AutoRange()
    /// The latest averaged frame in raw units, kept so we can recompute
    /// temperatures when the emissivity changes (also while frozen).
    private var latestRaw: (width: Int, height: Int, values: [Float])?
    /// The camera's own grayscale image belonging to `latestRaw`.
    private var latestDetail: (width: Int, height: Int, values: [UInt8])?
    private var referenceAccumulator: (sum: [Float], count: Int)?
    private let referenceFrameCount = 25
    private var fpsCounter = (count: 0, since: Date())
    private var statusMessageTask: Task<Void, Never>?

    // MARK: - Camera control

    init() {
        if preferences.rememberSettings, let saved = ViewerSettings.load() {
            viewerSettings = saved
        }
        saveViewerSettingsOnChange()

        NotificationCenter.default.addObserver(forName: .appWillQuit, object: nil, queue: .main) { [cameraController] _ in
            cameraController.stop(waitUntilClosed: true)
        }
    }

    func startCamera() {
        cameraTask?.cancel()
        cameraInfo = nil
        connectionState = .connecting
        averager.reset()
        autoRange.reset()
        calibration.reset()

        let events = cameraController.start(source: cameraSource,
                                            settings: CameraSettings(automaticShutter: preferences.automaticShutter,
                                                                     burnProtection: preferences.burnProtection,
                                                                     imageAdjustments: preferences.imageAdjustments))
        cameraTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    func stopCamera() {
        cameraController.stop()
        cameraTask?.cancel()
        connectionState = .idle
    }

    func triggerShutter() {
        cameraController.send(.triggerShutter)
        calibration.expectManualCalibration()
        showMessage(String(localized: "Shutter triggered – camera is recalibrating"))
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case .searching:
            connectionState = .searching
        case .connecting:
            connectionState = .connecting
        case let .streaming(info):
            cameraInfo = info
            connectionState = .streaming
            // The camera starts in high gain; restore the user's choice after reconnecting.
            if gainMode != .high { cameraController.send(.setGain(gainMode)) }
        case let .frame(frame):
            process(frame)
            cameraController.frameHandled()
        case let .failure(message):
            connectionState = .failed(message)
        case let .message(message):
            showMessage(message)
        }
    }

    // MARK: - Frame processing

    private func process(_ raw: RawThermalFrame) {
        countFrame()

        switch calibration.update(counter: raw.cameraFrameCounter, meanTemperature: Self.meanKelvin(of: raw)) {
        case .frozen:
            // The camera repeats its last frame while it calibrates – nothing new to show or record.
            return
        case .calibrated:
            history.markCalibration()
            // Do not blend frames from before and after the correction.
            averager.reset()
            if referenceFrame != nil { referenceIsOutdated = true }
        case .normal:
            break
        }

        let averaged = averager.add(raw)
        guard !isFrozen else { return }

        latestRaw = (raw.width, raw.height, averaged)
        latestDetail = raw.detailImage.isEmpty ? nil : (raw.width, raw.height, raw.detailImage)
        rebuildFrame()
        recordHistory()
        recordVideoFrame()
    }

    /// Converts the latest raw frame to temperatures and updates everything derived from it.
    private func rebuildFrame() {
        guard let latestRaw else { return }
        let celsius = Radiometry.celsius(fromRaw: latestRaw.values, settings: radiometry)
        let frame = ThermalFrame(width: latestRaw.width, height: latestRaw.height, values: celsius).applying(orientation)
        absoluteFrame = frame
        collectReference(from: frame)
        updateDisplay()
    }

    /// Recomputes the displayed frame, its range and the colored image.
    private func updateDisplay() {
        guard let absoluteFrame else { return }

        var shown = absoluteFrame
        if isShowingDifference, let referenceFrame, let difference = absoluteFrame.subtracting(referenceFrame) {
            shown = difference
        }
        let statistics = shown.statistics()

        if isShowingDifference {
            // Symmetric around 0 K so "white" always means "unchanged".
            let extent = max(abs(statistics.minimum), abs(statistics.maximum), 1)
            displayRange = -extent...extent
        } else if rangeMode == .automatic {
            displayRange = autoRange.update(with: statistics)
        } else {
            displayRange = manualMinimum...max(manualMaximum, manualMinimum + 0.1)
        }

        displayFrame = shown
        displayStatistics = statistics

        if isShowingDetail, let latestDetail {
            // Measurements keep using the temperatures; only the picture comes from the camera.
            let detail = ThermalFrame(width: latestDetail.width, height: latestDetail.height,
                                      values: latestDetail.values.map(Float.init)).applying(orientation)
            image = ThermalRenderer.makeImage(frame: detail, palette: palette, range: 0...255)
        } else {
            image = ThermalRenderer.makeImage(
                frame: shown,
                palette: isShowingDifference ? .difference : palette,
                range: displayRange,
                isothermThreshold: (isothermEnabled && !isShowingDifference) ? isothermThreshold : nil
            )
        }
    }

    /// Average temperature of a raw frame in kelvin.
    private static func meanKelvin(of frame: RawThermalFrame) -> Float {
        let sum = frame.values.reduce(0) { $0 + Int($1) }
        return Float(sum) / Float(max(frame.values.count, 1)) / P3Protocol.rawUnitsPerKelvin
    }

    private func countFrame() {
        fpsCounter.count += 1
        let elapsed = Date().timeIntervalSince(fpsCounter.since)
        if elapsed >= 1 {
            framesPerSecond = Double(fpsCounter.count) / elapsed
            fpsCounter = (0, Date())
        }
    }

    private func orientationChanged() {
        // Positions and the reference no longer match the rotated image.
        spots.removeAll()
        boxes.removeAll()
        discardReference()
        autoRange.reset()
        rebuildFrame()
    }

    // MARK: - Display range

    /// Switches to manual range and freezes the current automatic range.
    func lockCurrentRange() {
        manualMinimum = (displayRange.lowerBound * 10).rounded(.down) / 10
        manualMaximum = (displayRange.upperBound * 10).rounded(.up) / 10
        rangeMode = .manual
    }

    // MARK: - Reference / difference mode

    /// Averages the next frames into a reference image (e.g. of the unpowered board).
    func captureReference() {
        referenceAccumulator = ([], 0)
        referenceCaptureProgress = 0
        isFrozen = false
    }

    func discardReference() {
        referenceIsOutdated = false
        referenceFrame = nil
        referenceAccumulator = nil
        referenceCaptureProgress = nil
        showDifference = false
    }

    private func collectReference(from frame: ThermalFrame) {
        guard var accumulator = referenceAccumulator else { return }
        if accumulator.sum.count != frame.values.count {
            accumulator = ([Float](repeating: 0, count: frame.values.count), 0)
        }
        for index in frame.values.indices { accumulator.sum[index] += frame.values[index] }
        accumulator.count += 1
        referenceCaptureProgress = Double(accumulator.count) / Double(referenceFrameCount)

        if accumulator.count >= referenceFrameCount {
            let count = Float(accumulator.count)
            referenceFrame = ThermalFrame(width: frame.width, height: frame.height, values: accumulator.sum.map { $0 / count })
            referenceIsOutdated = false
            referenceAccumulator = nil
            referenceCaptureProgress = nil
            showDifference = true
            showMessage(String(localized: "Reference saved – difference image active"))
        } else {
            referenceAccumulator = accumulator
        }
    }

    // MARK: - Measurements

    func addSpot(at point: PixelPoint) {
        let number = (spots.map(\.number).max() ?? 0) + 1
        spots.append(SpotMeasurement(number: number, point: point))
    }

    func addBox(_ rect: PixelRect) {
        let number = (boxes.map(\.number).max() ?? 0) + 1
        boxes.append(BoxMeasurement(number: number, rect: rect))
    }

    func moveSpot(id: SpotMeasurement.ID, to point: PixelPoint) {
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        spots[index].point = point
    }

    /// Moves a box to `origin` (top left corner), keeping it completely inside the image.
    func moveBox(id: BoxMeasurement.ID, to origin: PixelPoint) {
        guard let index = boxes.firstIndex(where: { $0.id == id }), let frame = displayFrame else { return }
        let rect = boxes[index].rect
        boxes[index].rect.x = min(max(origin.x, 0), frame.width - rect.width)
        boxes[index].rect.y = min(max(origin.y, 0), frame.height - rect.height)
    }

    func removeSpot(_ spot: SpotMeasurement) { spots.removeAll { $0.id == spot.id } }
    func removeBox(_ box: BoxMeasurement) { boxes.removeAll { $0.id == box.id } }

    func clearMeasurements() {
        spots.removeAll()
        boxes.removeAll()
    }

    /// Current value at a pixel of the displayed frame.
    func displayValue(at point: PixelPoint) -> Float? {
        guard let displayFrame, displayFrame.contains(point) else { return nil }
        return displayFrame.value(at: point)
    }

    /// Absolute temperature at a pixel, also in difference mode.
    func absoluteValue(at point: PixelPoint) -> Float? {
        guard let absoluteFrame, absoluteFrame.contains(point) else { return nil }
        return absoluteFrame.value(at: point)
    }

    func statistics(for box: BoxMeasurement) -> TemperatureStatistics? {
        displayFrame?.statistics(in: box.rect)
    }

    /// "45.2 °C" or, in difference mode, "+3.1 K".
    func formatted(_ value: Float) -> String {
        TemperatureFormat.value(value, isDifference: isShowingDifference)
    }

    // MARK: - History

    private func recordHistory() {
        guard let absoluteFrame else { return }
        var values: [String: Float] = ["Max": absoluteFrame.statistics().maximum]
        for spot in spots where absoluteFrame.contains(spot.point) {
            values[spot.label] = absoluteFrame.value(at: spot.point)
        }
        for box in boxes {
            values["\(box.label) max"] = absoluteFrame.statistics(in: box.rect).maximum
        }
        history.maximumAge = TimeInterval(preferences.historyDurationMinutes * 60)
        history.sampleInterval = preferences.historySampleInterval
        history.record(values)
    }

    func clearHistory() { history.clear() }

    func exportHistory() {
        do {
            let url = try SnapshotExporter.newFileURL(in: preferences.outputFolder, prefix: "history", extension: "csv")
            try history.csv().write(to: url, atomically: true, encoding: .utf8)
            lastSavedURL = url
            showMessage(String(localized: "History saved: \(url.lastPathComponent)"))
        } catch {
            showMessage(String(localized: "Saving failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Snapshot and video

    func saveSnapshot() {
        guard let absoluteFrame, let displayStatistics,
              let scene = makeAnnotationScene(),
              let rendered = AnnotatedImageRenderer.render(scene, scale: preferences.snapshotScale) else {
            showMessage(String(localized: "No image to save"))
            return
        }

        let metadata = SnapshotExporter.Metadata(
            date: Date(),
            camera: cameraInfo?.modelName ?? cameraSource.label,
            emissivity: radiometry.emissivity,
            reflectedTemperature: radiometry.reflectedTemperature,
            averagedFrames: averagedFrames,
            minimum: displayStatistics.minimum,
            maximum: displayStatistics.maximum,
            mean: displayStatistics.mean,
            spots: spots.compactMap { spot in
                displayValue(at: spot.point).map {
                    .init(label: spot.label, x: spot.point.x, y: spot.point.y, temperature: $0)
                }
            },
            boxes: boxes.compactMap { box in
                statistics(for: box).map {
                    .init(label: box.label, x: box.rect.x, y: box.rect.y, width: box.rect.width, height: box.rect.height,
                          minimum: $0.minimum, maximum: $0.maximum, mean: $0.mean)
                }
            },
            note: isShowingDifference ? "Values are differences to the reference in kelvin" : nil
        )

        do {
            let url = try SnapshotExporter.saveSnapshot(
                image: rendered, temperatures: absoluteFrame, metadata: metadata, folder: preferences.outputFolder,
                includeTemperatureCSV: preferences.saveTemperatureCSV, includeMetadataJSON: preferences.saveMetadataJSON
            )
            lastSavedURL = url
            showMessage(String(localized: "Snapshot saved: \(url.lastPathComponent)"))
        } catch {
            showMessage(String(localized: "Saving failed: \(error.localizedDescription)"))
        }
    }

    func toggleRecording() {
        if let recorder = videoRecorder {
            videoRecorder = nil
            Task {
                await recorder.finish()
                lastSavedURL = recorder.url
                showMessage(String(localized: "Video saved: \(recorder.url.lastPathComponent)"))
            }
            return
        }

        guard let image else {
            showMessage(String(localized: "No image to record"))
            return
        }
        do {
            let url = try SnapshotExporter.newFileURL(in: preferences.outputFolder, prefix: "thermal", extension: "mp4")
            videoScale = preferences.videoScale
            let size = AnnotatedImageRenderer.outputSize(imageWidth: image.width, imageHeight: image.height, scale: videoScale)
            videoRecorder = try VideoRecorder(url: url, size: size)
            showMessage(String(localized: "Recording …"))
        } catch {
            showMessage(String(localized: "Recording failed: \(error.localizedDescription)"))
        }
    }

    /// Scale of the running recording (fixed when it starts, so the video size stays constant).
    private var videoScale = 3

    #if os(macOS)
    func openOutputFolder() {
        SnapshotExporter.openFolder(preferences.outputFolder)
    }
    #endif

    private func recordVideoFrame() {
        guard let videoRecorder, let scene = makeAnnotationScene(),
              let rendered = AnnotatedImageRenderer.render(scene, scale: videoScale) else { return }
        videoRecorder.append(rendered)
    }

    /// Collects everything currently visible for export.
    private func makeAnnotationScene() -> AnnotationScene? {
        guard let image, let displayStatistics else { return nil }

        var scene = AnnotationScene(
            thermalImage: image,
            smoothInterpolation: smoothInterpolation,
            palette: isShowingDifference ? .difference : palette,
            rangeTopLabel: isShowingDetail ? String(localized: "Detail") : formatted(displayRange.upperBound),
            rangeBottomLabel: isShowingDetail ? "" : formatted(displayRange.lowerBound),
            footer: footerText()
        )
        scene.spots = spots.compactMap { spot in
            displayValue(at: spot.point).map { .init(point: spot.point, text: "\(spot.label)  \(formatted($0))") }
        }
        scene.boxes = boxes.compactMap { box in
            statistics(for: box).map { .init(rect: box.rect, text: boxLabel(box, $0)) }
        }
        if showHotAndColdMarkers {
            scene.hottest = .init(point: displayStatistics.hottest, text: maximumLabel(displayStatistics.maximum))
            scene.coldest = .init(point: displayStatistics.coldest, text: minimumLabel(displayStatistics.minimum))
        }
        return scene
    }

    private func footerText() -> String {
        let date = Date().formatted(date: .numeric, time: .standard)
        var parts = [date, "ε = \(TemperatureFormat.emissivity(radiometry.emissivity))"]
        if isShowingDifference { parts.append(String(localized: "ΔT to reference")) }
        if averagedFrames > 1 { parts.append(String(localized: "average of \(averagedFrames) frames")) }
        return parts.joined(separator: "   ·   ")
    }

    // MARK: - Labels shared by the screen overlay and exports

    /// "max 42.3 °C"
    func maximumLabel(_ value: Float) -> String {
        String(localized: "max \(formatted(value))")
    }

    /// "min 21.0 °C"
    func minimumLabel(_ value: Float) -> String {
        String(localized: "min \(formatted(value))")
    }

    /// "B1  max 42.3 °C  avg 38.0 °C"
    func boxLabel(_ box: BoxMeasurement, _ statistics: TemperatureStatistics) -> String {
        String(localized: "\(box.label)  max \(formatted(statistics.maximum))  avg \(formatted(statistics.mean))")
    }

    // MARK: - Status messages

    func showMessage(_ message: String) {
        statusMessage = message
        statusMessageTask?.cancel()
        statusMessageTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }
}

// MARK: - Remembered settings

/// The sidebar settings that are restored on the next launch.
struct ViewerSettings: Codable, Equatable {
    var palette = Palette.iron
    var imageMode = ImageMode.temperature
    var rangeMode = RangeMode.automatic
    var manualMinimum: Float = 20
    var manualMaximum: Float = 60
    var isothermEnabled = false
    var isothermThreshold: Float = 50
    var showHotAndColdMarkers = true
    var smoothInterpolation = true
    var orientation = ImageOrientation()
    var radiometry = RadiometricSettings()
    var averagedFrames = 4
    var gainMode = GainMode.high
    var historyWindow: TimeInterval = 60

    private static let key = "viewerSettings"

    static func load() -> ViewerSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ViewerSettings.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension AppModel {
    /// The current sidebar settings as one value.
    var viewerSettings: ViewerSettings {
        get {
            ViewerSettings(
                palette: palette, imageMode: imageMode, rangeMode: rangeMode, manualMinimum: manualMinimum, manualMaximum: manualMaximum,
                isothermEnabled: isothermEnabled, isothermThreshold: isothermThreshold,
                showHotAndColdMarkers: showHotAndColdMarkers, smoothInterpolation: smoothInterpolation,
                orientation: orientation, radiometry: radiometry, averagedFrames: averagedFrames,
                gainMode: gainMode, historyWindow: historyWindow
            )
        }
        set {
            palette = newValue.palette
            imageMode = newValue.imageMode
            rangeMode = newValue.rangeMode
            manualMinimum = newValue.manualMinimum
            manualMaximum = newValue.manualMaximum
            isothermEnabled = newValue.isothermEnabled
            isothermThreshold = newValue.isothermThreshold
            showHotAndColdMarkers = newValue.showHotAndColdMarkers
            smoothInterpolation = newValue.smoothInterpolation
            orientation = newValue.orientation
            radiometry = newValue.radiometry
            averagedFrames = newValue.averagedFrames
            gainMode = newValue.gainMode
            historyWindow = newValue.historyWindow
        }
    }

    /// Saves the sidebar settings whenever one of them changes.
    ///
    /// `withObservationTracking` calls `onChange` once for the next change of any
    /// property read in the first closure, so we re-register after every save.
    fileprivate func saveViewerSettingsOnChange() {
        withObservationTracking {
            _ = viewerSettings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.preferences.rememberSettings { self.viewerSettings.save() }
                self.saveViewerSettingsOnChange()
            }
        }
    }

    /// Restores all sidebar settings and preferences to their defaults.
    func resetAllSettings() {
        preferences.resetToDefaults()
        viewerSettings = ViewerSettings()
        UserDefaults.standard.removeObject(forKey: "viewerSettings")
    }
}

#if DEBUG
extension AppModel {
    /// For unit tests: shows a uniform 20 °C frame without a camera.
    func injectTestFrame(width: Int, height: Int) {
        absoluteFrame = ThermalFrame(width: width, height: height, values: [Float](repeating: 20, count: width * height))
        updateDisplay()
    }
}
#endif
