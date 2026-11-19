import Foundation

/// Static information read from the camera when connecting.
struct CameraInfo: Sendable, Equatable {
    var modelName: String
    var firmwareVersion: String
    var hardwareVersion: String
    var serialNumber: String
    var partNumber: String
}

/// Commands the UI can send to a running camera.
enum CameraCommand: Sendable {
    /// Close the shutter and recalibrate (non-uniformity correction, "NUC").
    case triggerShutter
    case setGain(GainMode)
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
