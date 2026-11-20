import Foundation

/// Static information read from the camera when connecting.
struct CameraInfo: Sendable, Equatable {
    var modelName: String
    var firmwareVersion: String
    var hardwareVersion: String
    var serialNumber: String
    var partNumber: String
}

enum CameraError: LocalizedError {
    /// No camera plugged in. The camera thread keeps looking for one.
    case notConnected
    /// The camera cannot do this on the current platform (e.g. commands on iPhone).
    case commandNotSupported
    /// Connected, but the camera sends nothing. Happens now and then; replugging helps.
    case noImageData

    var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "Camera not connected.")
        case .commandNotSupported: String(localized: "Not supported on this device yet.")
        case .noImageData: String(localized: "The camera sends no image. Unplug it and plug it back in.")
        }
    }
}

/// Settings of the camera's own grayscale image (the "Detail" view), 0 … 100 each.
/// They do not change the temperature data.
enum ImageAdjustment: String, CaseIterable, Identifiable, Sendable {
    case brightness
    case contrast
    case detailEnhancement
    case noiseReduction

    var id: String { rawValue }
}

/// Commands the UI can send to a running camera.
enum CameraCommand: Sendable {
    /// Close the shutter and recalibrate (non-uniformity correction, "NUC").
    case triggerShutter
    case setGain(GainMode)
    case setImageAdjustment(ImageAdjustment, Int)
    /// Lets the camera close its shutter when it sees the sun (protects the sensor).
    case setBurnProtection(Bool)
}

/// Common interface of the real camera and the simulated demo camera.
///
/// All methods are blocking and are called from the camera thread
/// of `CameraController` only.
protocol ThermalCamera: AnyObject {
    var model: CameraModel { get }

    func open() throws -> CameraInfo
    func startStreaming() throws
    /// Reads the next piece of data. Returns a frame once one is complete,
    /// otherwise nil – just call it again.
    func readFrame() throws -> RawThermalFrame?
    func perform(_ command: CameraCommand) throws
    func close()
}
