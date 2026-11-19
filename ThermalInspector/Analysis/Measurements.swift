import Foundation

/// What a click into the image does.
enum MeasurementTool: String, CaseIterable, Identifiable {
    /// Show the temperature under the mouse; drag spots and boxes to move them.
    case inspect
    /// Click to place a measurement point.
    case spot
    /// Drag to draw a measurement box (shows max / min / average).
    case box

    var id: String { rawValue }

    var name: String {
        switch self {
        case .inspect: String(localized: "Pointer")
        case .spot: String(localized: "Spot")
        case .box: String(localized: "Box")
        }
    }

    var systemImage: String {
        switch self {
        case .inspect: "cursorarrow"
        case .spot: "scope"
        case .box: "square.dashed"
        }
    }
}

/// A fixed measurement point, e.g. on a voltage regulator.
struct SpotMeasurement: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    var point: PixelPoint

    var label: String { "P\(number)" }
}

/// A measurement box, e.g. around a whole IC.
struct BoxMeasurement: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    var rect: PixelRect

    var label: String { "B\(number)" }
}
