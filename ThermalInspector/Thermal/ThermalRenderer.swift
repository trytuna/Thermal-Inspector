import CoreGraphics
import Foundation

/// Turns a thermal frame into a colored image.
enum ThermalRenderer {
    /// Renders `frame` with `palette`, mapping `range` onto the full palette.
    ///
    /// - Parameter isothermThreshold: if set, only pixels at or above this value
    ///   are colored; everything colder is shown in gray. Makes hot spots jump out.
    static func makeImage(frame: ThermalFrame, palette: Palette, range: ClosedRange<Float>,
                          isothermThreshold: Float? = nil) -> CGImage? {
        let colors = palette.colors
        let span = max(range.upperBound - range.lowerBound, 0.001)
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 255, count: frame.width * frame.height * bytesPerPixel)

        for (index, value) in frame.values.enumerated() {
            let normalized = min(max((value - range.lowerBound) / span, 0), 1)
            let paletteIndex = Int(normalized * 255)
            let offset = index * bytesPerPixel

            if let threshold = isothermThreshold, value < threshold {
                // Dimmed gray, so the colored areas above the threshold stand out.
                let gray = UInt8(40 + normalized * 140)
                pixels[offset] = gray
                pixels[offset + 1] = gray
                pixels[offset + 2] = gray
            } else {
                let color = colors[paletteIndex]
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: frame.width, height: frame.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * bytesPerPixel,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

/// Automatic display range that follows the scene smoothly instead of flickering.
struct AutoRange {
    /// The range never gets narrower than this (in K), so pure sensor noise
    /// on an evenly warm board is not blown up into colorful blotches.
    var minimumSpan: Float = 2
    /// How quickly the range follows changes (0…1 per frame).
    var smoothing: Float = 0.15

    private var current: ClosedRange<Float>?

    mutating func update(with statistics: TemperatureStatistics) -> ClosedRange<Float> {
        var lower = statistics.minimum
        var upper = statistics.maximum

        if let current {
            lower = current.lowerBound + (lower - current.lowerBound) * smoothing
            upper = current.upperBound + (upper - current.upperBound) * smoothing
            // A new hot spot should show up immediately, not fade in.
            upper = max(upper, statistics.maximum)
            lower = min(lower, statistics.minimum)
        }

        if upper - lower < minimumSpan {
            let center = (upper + lower) / 2
            lower = center - minimumSpan / 2
            upper = center + minimumSpan / 2
        }

        let range = lower...upper
        current = range
        return range
    }

    mutating func reset() { current = nil }
}

/// Formats temperatures consistently throughout the app, using the user's
/// locale for the decimal separator ("42.3 °C" in English, "42,3 °C" in German).
enum TemperatureFormat {
    /// "42.3 °C"
    static func absolute(_ celsius: Float) -> String {
        "\(celsius.formatted(.number.precision(.fractionLength(1)))) °C"
    }

    /// "+3.2 K"
    static func difference(_ kelvin: Float) -> String {
        "\(kelvin.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))) K"
    }

    /// "0.95"
    static func emissivity(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    static func value(_ value: Float, isDifference: Bool) -> String {
        isDifference ? difference(value) : absolute(value)
    }
}
