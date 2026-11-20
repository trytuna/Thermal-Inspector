import Foundation

/// A fake camera that renders a small circuit board warming up after power-on.
///
/// Useful to try the app without hardware. It produces raw frames exactly like
/// the real camera, so the whole processing pipeline is exercised.
final class SimulatedCamera: ThermalCamera {
    let model = CameraModel.p3

    private let frameInterval: TimeInterval = 1.0 / 25.0
    private var startTime = Date()
    private var nextFrameTime = Date()
    private var frameNumber: UInt32 = 0
    private var components: [Component] = []
    private var shutterClosedUntil = Date.distantPast

    // Simulated drift and automatic recalibration, like the real P3 (see CalibrationMonitor).
    private let calibrationInterval: TimeInterval = 45
    private let calibrationDuration: TimeInterval = 0.8
    private let automaticCalibration: Bool

    init(automaticCalibration: Bool = true) {
        self.automaticCalibration = automaticCalibration
    }
    private var lastCalibration = Date()
    private var counter: UInt16 = 0
    private var lastFrame: RawThermalFrame?

    /// A heat source on the virtual board.
    private struct Component {
        /// Normalized heat footprint (0…1 per pixel).
        let footprint: [Float]
        /// Temperature rise above the board at steady state, in Kelvin.
        let steadyStateRise: Float
        /// Thermal time constant in seconds.
        let timeConstant: Double
        /// Seconds after power-on before it starts heating.
        let delay: Double

        func rise(after seconds: Double) -> Float {
            let heatingTime = seconds - delay
            guard heatingTime > 0 else { return 0 }
            return steadyStateRise * Float(1 - exp(-heatingTime / timeConstant))
        }
    }

    func open() throws -> CameraInfo {
        let width = model.width, height = model.height
        components = [
            // Microcontroller in a QFN package
            Component(footprint: Self.rectangle(x: 70, y: 70, width: 44, height: 44, softness: 4, imageWidth: width, imageHeight: height),
                      steadyStateRise: 24, timeConstant: 25, delay: 0),
            // Linear voltage regulator (SOT-223)
            Component(footprint: Self.rectangle(x: 170, y: 40, width: 18, height: 14, softness: 3, imageWidth: width, imageHeight: height),
                      steadyStateRise: 42, timeConstant: 12, delay: 0),
            // Shorted ceramic capacitor – the "fault" to find
            Component(footprint: Self.spot(x: 150, y: 140, radius: 2.5, imageWidth: width, imageHeight: height),
                      steadyStateRise: 55, timeConstant: 4, delay: 6),
            // A few resistors
            Component(footprint: Self.rectangle(x: 40, y: 150, width: 8, height: 4, softness: 2, imageWidth: width, imageHeight: height),
                      steadyStateRise: 9, timeConstant: 6, delay: 0),
            Component(footprint: Self.rectangle(x: 210, y: 120, width: 8, height: 4, softness: 2, imageWidth: width, imageHeight: height),
                      steadyStateRise: 12, timeConstant: 6, delay: 0),
        ]
        return CameraInfo(modelName: String(localized: "Demo camera"), firmwareVersion: "–",
                          hardwareVersion: String(localized: "Simulation"),
                          serialNumber: "–", partNumber: "–")
    }

    func startStreaming() throws {
        startTime = Date()
        nextFrameTime = startTime
        lastCalibration = startTime
    }

    /// Offset the sensor has drifted since the last calibration. Drifts fast while
    /// the camera warms up and slower later, like the real camera.
    private func drift(now: Date) -> Float {
        let warmUp = exp(-now.timeIntervalSince(startTime) / 240)
        let rate = 0.005 + 0.04 * warmUp   // K per second
        return -Float(rate * now.timeIntervalSince(lastCalibration))
    }

    func readFrame() throws -> RawThermalFrame? {
        // Pace the output to 25 fps like the real camera.
        let delay = nextFrameTime.timeIntervalSinceNow
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        nextFrameTime = max(nextFrameTime.addingTimeInterval(frameInterval), Date())

        let now = Date()
        let secondsSinceCalibration = now.timeIntervalSince(lastCalibration)

        // During calibration the real camera repeats its last frame.
        if automaticCalibration, secondsSinceCalibration >= calibrationInterval, let lastFrame {
            if secondsSinceCalibration < calibrationInterval + calibrationDuration { return lastFrame }
            lastCalibration = now
            counter &+= 6
        }

        let width = model.width, height = model.height
        let seconds = now.timeIntervalSince(startTime)
        let rises = components.map { $0.rise(after: seconds) }
        let shutterClosed = now < shutterClosedUntil
        let offset = drift(now: now)

        var values = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                var celsius: Float
                if shutterClosed {
                    celsius = 30
                } else {
                    // Board at ~27 °C with a slight gradient, plus all components, plus sensor noise.
                    celsius = 26.5 + Float(x) / Float(width) * 1.5
                    for (component, rise) in zip(components, rises) {
                        celsius += component.footprint[index] * rise
                    }
                }
                celsius += offset + Float.random(in: -0.12...0.12)
                let kelvin = celsius + P3Protocol.kelvinOffset
                values[index] = UInt16(kelvin * P3Protocol.rawUnitsPerKelvin)
            }
        }

        frameNumber &+= 1
        counter &+= 1
        let frame = RawThermalFrame(width: width, height: height, values: values, frameNumber: frameNumber,
                                    detailImage: Self.detailImage(from: values), cameraFrameCounter: counter)
        lastFrame = frame
        return frame
    }

    /// A stand-in for the camera's own image processing: contrast-stretched gray.
    private static func detailImage(from values: [UInt16]) -> [UInt8] {
        guard let low = values.min(), let high = values.max(), high > low else {
            return [UInt8](repeating: 128, count: values.count)
        }
        let span = Float(high - low)
        // Square root brightens the board, so the (cooler) structure stays visible next to hot parts.
        return values.map { UInt8((Float($0 - low) / span).squareRoot() * 255) }
    }

    func perform(_ command: CameraCommand) throws {
        switch command {
        case .triggerShutter:
            shutterClosedUntil = Date().addingTimeInterval(0.4)
            lastCalibration = Date()
            counter &+= 6
        case .setGain, .setImageAdjustment, .setBurnProtection:
            break
        }
    }

    func close() {}

    // MARK: Footprint shapes

    private static func rectangle(x: Int, y: Int, width: Int, height: Int, softness: Float,
                                  imageWidth: Int, imageHeight: Int) -> [Float] {
        var footprint = [Float](repeating: 0, count: imageWidth * imageHeight)
        for py in 0..<imageHeight {
            for px in 0..<imageWidth {
                // Distance outside the rectangle (0 inside), heat fades out over `softness` pixels.
                let dx = max(Float(x - px), 0, Float(px - (x + width)))
                let dy = max(Float(y - py), 0, Float(py - (y + height)))
                let distance = (dx * dx + dy * dy).squareRoot()
                footprint[py * imageWidth + px] = exp(-(distance * distance) / (2 * softness * softness))
            }
        }
        return footprint
    }

    private static func spot(x: Int, y: Int, radius: Float, imageWidth: Int, imageHeight: Int) -> [Float] {
        var footprint = [Float](repeating: 0, count: imageWidth * imageHeight)
        for py in 0..<imageHeight {
            for px in 0..<imageWidth {
                let dx = Float(px - x), dy = Float(py - y)
                footprint[py * imageWidth + px] = exp(-(dx * dx + dy * dy) / (2 * radius * radius))
            }
        }
        return footprint
    }
}
