import CoreGraphics
import SwiftUI

/// An RGB color with 8 bits per channel.
struct RGB: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var cgColor: CGColor {
        CGColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

/// Color palettes that map temperatures to colors.
enum Palette: String, CaseIterable, Identifiable, Codable, Sendable {
    case iron
    case rainbow
    case whiteHot
    case blackHot
    case lava
    case arctic
    /// Diverging blue–white–red palette used for difference images.
    case difference

    var id: String { rawValue }

    /// Palettes offered in the UI for normal (absolute) images.
    static let selectable: [Palette] = [.iron, .rainbow, .whiteHot, .blackHot, .lava, .arctic]

    var name: String {
        switch self {
        case .iron: String(localized: "Iron")
        case .rainbow: String(localized: "Rainbow")
        case .whiteHot: String(localized: "White hot")
        case .blackHot: String(localized: "Black hot")
        case .lava: String(localized: "Lava")
        case .arctic: String(localized: "Arctic")
        case .difference: String(localized: "Difference")
        }
    }

    /// Lookup table with 256 colors from cold (index 0) to hot (index 255).
    var colors: [RGB] { Self.lookupTables[self]! }

    /// The colors the lookup table is interpolated from, evenly spaced from cold to hot.
    private var colorStops: [RGB] {
        switch self {
        case .iron:
            [RGB(0, 0, 0), RGB(30, 0, 90), RGB(120, 0, 150), RGB(200, 30, 100),
             RGB(240, 90, 0), RGB(255, 180, 0), RGB(255, 240, 120), RGB(255, 255, 255)]
        case .rainbow:
            [RGB(20, 0, 80), RGB(0, 0, 255), RGB(0, 255, 255), RGB(0, 255, 0),
             RGB(255, 255, 0), RGB(255, 0, 0), RGB(255, 210, 210)]
        case .whiteHot:
            [RGB(0, 0, 0), RGB(255, 255, 255)]
        case .blackHot:
            [RGB(255, 255, 255), RGB(0, 0, 0)]
        case .lava:
            [RGB(0, 0, 0), RGB(80, 0, 0), RGB(180, 20, 0), RGB(255, 120, 0), RGB(255, 220, 80), RGB(255, 255, 255)]
        case .arctic:
            [RGB(0, 0, 40), RGB(0, 60, 160), RGB(0, 170, 220), RGB(200, 240, 255), RGB(255, 220, 120), RGB(255, 140, 0)]
        case .difference:
            [RGB(0, 40, 180), RGB(90, 150, 255), RGB(245, 245, 245), RGB(255, 140, 90), RGB(200, 0, 0)]
        }
    }

    private static let lookupTables: [Palette: [RGB]] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, interpolate($0.colorStops, count: 256)) }
    )

    /// Linearly interpolates `stops` into `count` colors.
    private static func interpolate(_ stops: [RGB], count: Int) -> [RGB] {
        (0..<count).map { index in
            let position = Double(index) / Double(count - 1) * Double(stops.count - 1)
            let lower = min(Int(position), stops.count - 2)
            let fraction = position - Double(lower)
            func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
                UInt8((Double(a) + (Double(b) - Double(a)) * fraction).rounded())
            }
            let a = stops[lower], b = stops[lower + 1]
            return RGB(mix(a.red, b.red), mix(a.green, b.green), mix(a.blue, b.blue))
        }
    }

    /// A SwiftUI gradient from cold (bottom) to hot (top), for color bars.
    var verticalGradient: LinearGradient {
        let stops = stride(from: 0, to: 256, by: 16).map { index in
            let color = colors[index]
            return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
        }
        return LinearGradient(colors: stops, startPoint: .bottom, endPoint: .top)
    }
}
