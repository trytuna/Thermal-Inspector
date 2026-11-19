import Foundation

/// A pixel position in a thermal image (origin top left).
struct PixelPoint: Hashable, Codable, Sendable {
    var x: Int
    var y: Int
}

/// A rectangular area of pixels in a thermal image.
struct PixelRect: Hashable, Codable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    /// The rectangle spanned by two corner points (in any order), both included.
    init(from a: PixelPoint, to b: PixelPoint) {
        x = min(a.x, b.x)
        y = min(a.y, b.y)
        width = abs(a.x - b.x) + 1
        height = abs(a.y - b.y) + 1
    }

    var center: PixelPoint { PixelPoint(x: x + width / 2, y: y + height / 2) }
}

/// Minimum, maximum and average temperature of a frame or a region.
struct TemperatureStatistics: Sendable, Equatable {
    var minimum: Float
    var maximum: Float
    var mean: Float
    var coldest: PixelPoint
    var hottest: PixelPoint
}

/// How the image is rotated and mirrored for display (e.g. camera mounted upside down over a board).
struct ImageOrientation: Equatable, Codable, Sendable {
    /// Number of clockwise quarter turns (0…3).
    var quarterTurns = 0
    var mirroredHorizontally = false
    var mirroredVertically = false

    mutating func rotateClockwise() { quarterTurns = (quarterTurns + 1) % 4 }
    mutating func rotateCounterClockwise() { quarterTurns = (quarterTurns + 3) % 4 }

    var isIdentity: Bool { self == ImageOrientation() }
}

/// A grid of temperatures (°C) – or, in difference mode, of temperature differences (K).
struct ThermalFrame: Sendable {
    let width: Int
    let height: Int
    /// Row-major values, `width * height` entries.
    var values: [Float]

    func value(at point: PixelPoint) -> Float {
        values[point.y * width + point.x]
    }

    func contains(_ point: PixelPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < width && point.y < height
    }

    /// Statistics of the whole frame, or of `region` (clipped to the frame).
    func statistics(in region: PixelRect? = nil) -> TemperatureStatistics {
        let x0 = max(region?.x ?? 0, 0)
        let y0 = max(region?.y ?? 0, 0)
        let x1 = min((region.map { $0.x + $0.width }) ?? width, width)
        let y1 = min((region.map { $0.y + $0.height }) ?? height, height)

        var result = TemperatureStatistics(minimum: .infinity, maximum: -.infinity, mean: 0,
                                           coldest: PixelPoint(x: x0, y: y0), hottest: PixelPoint(x: x0, y: y0))
        guard x1 > x0, y1 > y0 else {
            result.minimum = 0
            result.maximum = 0
            return result
        }

        var sum: Double = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let value = values[y * width + x]
                sum += Double(value)
                if value < result.minimum {
                    result.minimum = value
                    result.coldest = PixelPoint(x: x, y: y)
                }
                if value > result.maximum {
                    result.maximum = value
                    result.hottest = PixelPoint(x: x, y: y)
                }
            }
        }
        result.mean = Float(sum / Double((x1 - x0) * (y1 - y0)))
        return result
    }

    /// Returns the frame mirrored and then rotated as described by `orientation`.
    func applying(_ orientation: ImageOrientation) -> ThermalFrame {
        guard !orientation.isIdentity else { return self }

        let turns = orientation.quarterTurns
        let outputWidth = turns.isMultiple(of: 2) ? width : height
        let outputHeight = turns.isMultiple(of: 2) ? height : width
        var output = [Float](repeating: 0, count: values.count)

        for y in 0..<height {
            for x in 0..<width {
                // 1. Mirror
                let mx = orientation.mirroredHorizontally ? width - 1 - x : x
                let my = orientation.mirroredVertically ? height - 1 - y : y
                // 2. Rotate clockwise
                let (ox, oy): (Int, Int) = switch turns {
                case 1: (height - 1 - my, mx)
                case 2: (width - 1 - mx, height - 1 - my)
                case 3: (my, width - 1 - mx)
                default: (mx, my)
                }
                output[oy * outputWidth + ox] = values[y * width + x]
            }
        }
        return ThermalFrame(width: outputWidth, height: outputHeight, values: output)
    }

    /// Pixel-wise difference `self - reference`. Both frames must have the same size.
    func subtracting(_ reference: ThermalFrame) -> ThermalFrame? {
        guard reference.width == width, reference.height == height else { return nil }
        let difference = zip(values, reference.values).map { $0 - $1 }
        return ThermalFrame(width: width, height: height, values: difference)
    }
}
