// Draws the app icon (1024 × 1024 PNG): a chip seen through a thermal camera,
// in the app's "Iron" palette, with a measurement crosshair on its hot spot.
//
// Usage: swift Tools/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

// The "Iron" palette (cold → hot), same color stops as Palette.iron in the app.
let ironStops: [(Double, Double, Double)] = [
    (0, 0, 0), (30, 0, 90), (120, 0, 150), (200, 30, 100),
    (240, 90, 0), (255, 180, 0), (255, 240, 120), (255, 255, 255),
]

func ironColor(_ t: Double) -> (UInt8, UInt8, UInt8) {
    let position = min(max(t, 0), 1) * Double(ironStops.count - 1)
    let lower = min(Int(position), ironStops.count - 2)
    let f = position - Double(lower)
    let a = ironStops[lower], b = ironStops[lower + 1]
    return (UInt8(a.0 + (b.0 - a.0) * f), UInt8(a.1 + (b.1 - a.1) * f), UInt8(a.2 + (b.2 - a.2) * f))
}

// Icon geometry (macOS icon grid: 824 pt body on a 1024 canvas).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185
let chip = CGRect(x: 362, y: 362, width: 300, height: 300)
let hotSpot = CGPoint(x: 560, y: 470)   // top-left based coordinates

// MARK: Heat field rendered as a bitmap

/// "Temperature" (0…1) at a point: warm chip, hotter spot on it, a few warm parts around.
func heat(x: Double, y: Double) -> Double {
    func gaussian(_ cx: Double, _ cy: Double, _ sigma: Double) -> Double {
        let dx = x - cx, dy = y - cy
        return exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
    }
    func softBox(_ r: CGRect, _ softness: Double) -> Double {
        let dx = max(r.minX - x, 0, x - r.maxX)
        let dy = max(r.minY - y, 0, y - r.maxY)
        let d = (dx * dx + dy * dy).squareRoot()
        return exp(-(d * d) / (2 * softness * softness))
    }
    var value = 0.08 + 0.05 * (y / Double(size))         // cool board
    value += 0.38 * softBox(chip, 55)                   // the chip
    value += 0.48 * gaussian(hotSpot.x, hotSpot.y, 80)  // its hot spot
    value += 0.22 * softBox(CGRect(x: 205, y: 250, width: 70, height: 40), 22) // small parts
    value += 0.18 * softBox(CGRect(x: 740, y: 720, width: 50, height: 80), 22)
    value += 0.15 * softBox(CGRect(x: 230, y: 730, width: 90, height: 34), 20)
    return min(value, 0.93)
}

var pixels = [UInt8](repeating: 255, count: size * size * 4)
for y in 0..<size {
    for x in 0..<size {
        let (r, g, b) = ironColor(heat(x: Double(x), y: Double(y)))
        let offset = (y * size + x) * 4
        pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b
    }
}
let heatImage = CGImage(
    width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
    provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent
)!

// MARK: Composition

let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work top-left based like the heat field.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

let bodyPath = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

// Soft drop shadow
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
context.addPath(bodyPath)
context.setFillColor(CGColor(gray: 0.1, alpha: 1))
context.fillPath()
context.restoreGState()

// Thermal image, clipped to the icon body (drawn un-flipped so it matches the heat field)
context.saveGState()
context.addPath(bodyPath)
context.clip()
context.saveGState()
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.draw(heatImage, in: CGRect(x: 0, y: 0, width: size, height: size))
context.restoreGState()

// Chip outline with pins
let line = CGColor(red: 1, green: 1, blue: 1, alpha: 0.55)
context.setStrokeColor(line)
context.setLineWidth(10)
context.addPath(CGPath(roundedRect: chip, cornerWidth: 26, cornerHeight: 26, transform: nil))
context.strokePath()
context.setLineCap(.round)
for i in 0..<5 {
    let offset = chip.minX + 50 + CGFloat(i) * 50
    for (from, to) in [
        (CGPoint(x: offset, y: chip.minY - 14), CGPoint(x: offset, y: chip.minY - 54)),
        (CGPoint(x: offset, y: chip.maxY + 14), CGPoint(x: offset, y: chip.maxY + 54)),
        (CGPoint(x: chip.minX - 14, y: offset), CGPoint(x: chip.minX - 54, y: offset)),
        (CGPoint(x: chip.maxX + 14, y: offset), CGPoint(x: chip.maxX + 54, y: offset)),
    ] {
        context.move(to: from); context.addLine(to: to)
    }
}
context.strokePath()

// Measurement crosshair on the hot spot
for (color, width) in [(CGColor(gray: 0, alpha: 0.45), 20.0), (CGColor(gray: 1, alpha: 1), 9.0)] {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.strokeEllipse(in: CGRect(x: hotSpot.x - 58, y: hotSpot.y - 58, width: 116, height: 116))
    for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
        context.move(to: CGPoint(x: hotSpot.x + dx * 58, y: hotSpot.y + dy * 58))
        context.addLine(to: CGPoint(x: hotSpot.x + dx * 112, y: hotSpot.y + dy * 112))
    }
    context.strokePath()
}

// Subtle glass highlight along the top edge
let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
context.drawLinearGradient(highlight, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.minY + 260), options: [])
context.restoreGState()

// Thin rim
context.addPath(bodyPath)
context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
context.setLineWidth(3)
context.strokePath()

let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
