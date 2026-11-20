import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The app's user interface language.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow the macOS language settings.
    case system
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Languages are shown in their own language ("Deutsch", not "German"),
    /// so users can always find theirs.
    var name: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .german: "Deutsch"
        }
    }
}

/// App-wide preferences, edited in the Settings window (⌘,) and stored in UserDefaults.
///
/// The settings in the sidebar (palette, emissivity, …) are not here – those are
/// remembered by `AppModel` itself when "Remember settings" is enabled.
@MainActor
@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    // MARK: General

    /// Takes effect after restarting the app. (On iOS the language is chosen in the
    /// system Settings app, as usual there.)
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            // macOS picks the app language from the "AppleLanguages" setting of the app.
            if language == .system {
                defaults.removeObject(forKey: Key.appleLanguages)
            } else {
                defaults.set([language.rawValue], forKey: Key.appleLanguages)
            }
        }
    }

    /// The language the app was started with – to tell whether a restart is needed.
    let launchLanguage: AppLanguage

    /// Restore palette, emissivity, orientation etc. from the last session.
    var rememberSettings: Bool {
        didSet { defaults.set(rememberSettings, forKey: Key.rememberSettings) }
    }

    // MARK: Camera

    /// Whether the camera recalibrates itself about every 90 seconds. Off keeps the
    /// image free of sudden jumps (e.g. for recordings), but readings drift slowly.
    var automaticShutter: Bool {
        didSet { defaults.set(automaticShutter, forKey: Key.automaticShutter) }
    }

    /// The camera closes its shutter when it sees the sun, to protect the sensor.
    var burnProtection: Bool {
        didSet { defaults.set(burnProtection, forKey: Key.burnProtection) }
    }

    /// Settings of the camera's grayscale image. Missing ones keep the camera's own value.
    var imageAdjustments: [ImageAdjustment: Int] {
        didSet {
            for adjustment in ImageAdjustment.allCases {
                defaults.set(imageAdjustments[adjustment] ?? -1, forKey: Key.imageAdjustment(adjustment))
            }
        }
    }

    // MARK: Export

    var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }

    /// Also write the full temperature matrix as CSV with every snapshot.
    var saveTemperatureCSV: Bool {
        didSet { defaults.set(saveTemperatureCSV, forKey: Key.saveTemperatureCSV) }
    }

    /// Also write settings and measurement results as JSON with every snapshot.
    var saveMetadataJSON: Bool {
        didSet { defaults.set(saveMetadataJSON, forKey: Key.saveMetadataJSON) }
    }

    /// Magnification of exported snapshots (256 × 192 sensor pixels × scale).
    var snapshotScale: Int {
        didSet { defaults.set(snapshotScale, forKey: Key.snapshotScale) }
    }

    /// Magnification of recorded videos.
    var videoScale: Int {
        didSet { defaults.set(videoScale, forKey: Key.videoScale) }
    }

    // MARK: History

    /// How long the temperature history is kept, in minutes.
    var historyDurationMinutes: Int {
        didSet { defaults.set(historyDurationMinutes, forKey: Key.historyDuration) }
    }

    /// Time between two history samples, in seconds.
    var historySampleInterval: Double {
        didSet { defaults.set(historySampleInterval, forKey: Key.historySampleInterval) }
    }

    // MARK: Loading and resetting

    /// Default values, used until the user changes something.
    private static let defaultValues: [String: Any] = [
        Key.language: AppLanguage.system.rawValue,
        Key.rememberSettings: true,
        Key.automaticShutter: true,
        Key.burnProtection: true,
        // Brightness and contrast as the official app sets them; −1 = camera's own value.
        Key.imageAdjustment(.brightness): 50,
        Key.imageAdjustment(.contrast): 50,
        Key.imageAdjustment(.detailEnhancement): -1,
        Key.imageAdjustment(.noiseReduction): -1,
        Key.outputFolder: SnapshotExporter.defaultOutputFolder.path,
        Key.saveTemperatureCSV: true,
        Key.saveMetadataJSON: true,
        Key.snapshotScale: 4,
        Key.videoScale: 3,
        Key.historyDuration: 30,
        Key.historySampleInterval: 0.2,
    ]

    init() {
        // Registered defaults apply whenever a key is not set. The typed getters
        // (bool, integer, …) also understand launch arguments like "-rememberSettings NO".
        defaults.register(defaults: Self.defaultValues)

        let storedLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        language = storedLanguage
        launchLanguage = storedLanguage
        rememberSettings = defaults.bool(forKey: Key.rememberSettings)
        automaticShutter = defaults.bool(forKey: Key.automaticShutter)
        burnProtection = defaults.bool(forKey: Key.burnProtection)
        var adjustments: [ImageAdjustment: Int] = [:]
        for adjustment in ImageAdjustment.allCases {
            let value = defaults.integer(forKey: Key.imageAdjustment(adjustment))
            if value >= 0 { adjustments[adjustment] = value }
        }
        imageAdjustments = adjustments
        #if os(macOS)
        outputFolder = URL(fileURLWithPath: defaults.string(forKey: Key.outputFolder) ?? "", isDirectory: true)
        #else
        // The Documents path changes with every install, so it is never stored on iOS.
        outputFolder = SnapshotExporter.defaultOutputFolder
        #endif
        saveTemperatureCSV = defaults.bool(forKey: Key.saveTemperatureCSV)
        saveMetadataJSON = defaults.bool(forKey: Key.saveMetadataJSON)
        snapshotScale = defaults.integer(forKey: Key.snapshotScale)
        videoScale = defaults.integer(forKey: Key.videoScale)
        historyDurationMinutes = defaults.integer(forKey: Key.historyDuration)
        historySampleInterval = defaults.double(forKey: Key.historySampleInterval)
    }

    var needsRestartForLanguage: Bool { language != launchLanguage }

    /// Sets all preferences back to their defaults (language included).
    func resetToDefaults() {
        for key in Self.defaultValues.keys { defaults.removeObject(forKey: key) }
        language = .system
        rememberSettings = true
        automaticShutter = true
        burnProtection = true
        imageAdjustments = [.brightness: 50, .contrast: 50]
        outputFolder = SnapshotExporter.defaultOutputFolder
        saveTemperatureCSV = true
        saveMetadataJSON = true
        snapshotScale = 4
        videoScale = 3
        historyDurationMinutes = 30
        historySampleInterval = 0.2
    }

    #if os(macOS)
    /// Asks the user for a new output folder.
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    /// Starts a new instance of the app and quits this one (e.g. to apply the language).
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif

    private enum Key {
        static let language = "language"
        static let appleLanguages = "AppleLanguages"
        static let rememberSettings = "rememberSettings"
        static let automaticShutter = "automaticShutter"
        static let burnProtection = "burnProtection"
        static func imageAdjustment(_ adjustment: ImageAdjustment) -> String { "image_" + adjustment.rawValue }
        static let outputFolder = "outputFolder"
        static let saveTemperatureCSV = "saveTemperatureCSV"
        static let saveMetadataJSON = "saveMetadataJSON"
        static let snapshotScale = "snapshotScale"
        static let videoScale = "videoScale"
        static let historyDuration = "historyDurationMinutes"
        static let historySampleInterval = "historySampleInterval"
    }
}
