import Foundation

/// Parameters that turn the camera's raw signal into an object temperature.
struct RadiometricSettings: Equatable, Codable, Sendable {
    /// How well the surface radiates (0…1). FR-4 solder mask ≈ 0.9, bare metal is much lower.
    var emissivity: Float = 0.95
    /// Temperature of the surroundings that the object reflects, in °C.
    var reflectedTemperature: Float = 25
}

/// A typical emissivity value for a material found on circuit boards.
struct EmissivityPreset: Identifiable, Hashable {
    let name: String
    let emissivity: Float
    var id: String { name }

    static let all: [EmissivityPreset] = [
        EmissivityPreset(name: String(localized: "Black electrical tape / matte paint"), emissivity: 0.95),
        EmissivityPreset(name: String(localized: "IC package (epoxy)"), emissivity: 0.93),
        EmissivityPreset(name: String(localized: "Solder mask (FR-4)"), emissivity: 0.90),
        EmissivityPreset(name: String(localized: "Ceramic (capacitors)"), emissivity: 0.90),
        EmissivityPreset(name: String(localized: "Plastic connectors"), emissivity: 0.85),
        EmissivityPreset(name: String(localized: "Copper, oxidized"), emissivity: 0.65),
        EmissivityPreset(name: String(localized: "Solder / tinned"), emissivity: 0.10),
        EmissivityPreset(name: String(localized: "Aluminum, bare"), emissivity: 0.05),
    ]
}

enum Radiometry {
    /// Converts raw sensor values (1/64 K) to object temperatures in °C.
    ///
    /// With an emissivity below 1 the camera sees a mix of the object's own
    /// radiation and reflected radiation from the surroundings. We undo that
    /// with the Stefan–Boltzmann correction:
    ///
    ///     T_object⁴ = (T_apparent⁴ − (1 − ε) · T_reflected⁴) / ε
    static func celsius(fromRaw raw: [Float], settings: RadiometricSettings) -> [Float] {
        let emissivity = settings.emissivity
        let kelvinOffset = P3Protocol.kelvinOffset
        let scale = P3Protocol.rawUnitsPerKelvin

        guard emissivity > 0, emissivity < 0.999 else {
            return raw.map { $0 / scale - kelvinOffset }
        }

        let reflectedKelvin = settings.reflectedTemperature + kelvinOffset
        let reflectedPart = (1 - emissivity) * pow(reflectedKelvin, 4)

        return raw.map { value in
            let apparentKelvin = value / scale
            let objectKelvin4 = max((pow(apparentKelvin, 4) - reflectedPart) / emissivity, 0)
            return pow(objectKelvin4, 0.25) - kelvinOffset
        }
    }
}

/// Averages the last few frames to reduce sensor noise ("temporal noise reduction").
///
/// Averaging makes small temperature differences visible – useful on boards
/// that only warm up by a fraction of a degree – at the cost of some motion blur.
struct FrameAverager {
    /// Number of frames to average. 1 disables averaging.
    var frameCount = 4 {
        didSet { if frameCount != oldValue { reset() } }
    }

    private var history: [[Float]] = []
    private var sum: [Float] = []

    /// Adds a frame and returns the current average (still in raw units).
    mutating func add(_ frame: RawThermalFrame) -> [Float] {
        let values = frame.values.map(Float.init)
        if sum.count != values.count { reset() }
        if frameCount <= 1 { return values }

        if sum.isEmpty { sum = [Float](repeating: 0, count: values.count) }
        history.append(values)
        for index in sum.indices { sum[index] += values[index] }

        while history.count > frameCount {
            let oldest = history.removeFirst()
            for index in sum.indices { sum[index] -= oldest[index] }
        }

        let count = Float(history.count)
        return sum.map { $0 / count }
    }

    mutating func reset() {
        history.removeAll()
        sum.removeAll()
    }
}
