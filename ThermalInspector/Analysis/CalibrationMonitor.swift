import Foundation

/// Detects the camera's automatic recalibration (NUC, "non-uniformity correction")
/// in the frame stream and measures how much it corrected.
///
/// What the P3 does (observed, see docs/HARDWARE-NOTES.md):
///
/// 1. About every 90 seconds it closes the shutter for ~0.8 s. Meanwhile it keeps
///    sending the last frame again; its internal frame counter stands still.
/// 2. Afterwards the counter jumps ahead and the image is corrected. The whole
///    image can shift by several kelvin at once – that is how far the camera had
///    drifted since the previous calibration.
///
/// A large correction means the camera is still warming up and readings drift;
/// a small one means it is stable.
struct CalibrationMonitor {
    enum Event: Equatable {
        /// A regular new frame.
        case normal
        /// The camera repeats the previous frame because it is calibrating.
        case frozen
        /// A calibration just finished. `correction` is the change of the average
        /// image temperature in kelvin.
        case calibrated(correction: Float)
    }

    /// Corrections up to this size (K) count as "stable".
    static let stableCorrection: Float = 0.5

    private(set) var isCalibrating = false
    private(set) var lastCalibration: Date?
    private(set) var lastCorrection: Float?

    private var previousCounter: UInt16?
    private var previousMean: Float?
    /// Set when the user triggered the shutter; the next counter jump is that calibration.
    private var manualCalibrationExpected = false

    /// Whether the last observed calibration only needed a small correction.
    /// Nil until a calibration has been observed.
    var isStable: Bool? {
        lastCorrection.map { abs($0) <= Self.stableCorrection }
    }

    /// Call for every frame with the camera's frame counter and the average image temperature.
    mutating func update(counter: UInt16?, meanTemperature: Float, now: Date = Date()) -> Event {
        defer {
            previousCounter = counter
            previousMean = meanTemperature
        }
        guard let counter, let previousCounter, let previousMean else { return .normal }

        let step = counter &- previousCounter   // wraps around at 65535
        if step == 0 {
            isCalibrating = true
            return .frozen
        }

        // A calibration has finished after a freeze, or – for a manual shutter – when the counter jumps.
        // A jump alone is not enough: the app itself may have skipped frames while it was busy.
        if isCalibrating || (manualCalibrationExpected && step > 1) {
            isCalibrating = false
            manualCalibrationExpected = false
            let correction = meanTemperature - previousMean
            lastCalibration = now
            lastCorrection = correction
            return .calibrated(correction: correction)
        }
        return .normal
    }

    /// Call when the shutter was triggered manually.
    mutating func expectManualCalibration() {
        manualCalibrationExpected = true
    }

    mutating func reset() {
        self = CalibrationMonitor()
    }
}
