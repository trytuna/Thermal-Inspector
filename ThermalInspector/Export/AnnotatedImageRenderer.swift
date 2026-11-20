import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
#else
import UIKit
private typealias PlatformFont = UIFont
#endif

/// Everything that goes into an exported image (snapshot or video frame).
struct AnnotationScene {
    struct Marker {
        var point: PixelPoint
        var text: String
    }

    struct Box {
        var rect: PixelRect
        var text: String
    }

    var thermalImage: CGImage
    var smoothInterpolation: Bool
    var spots: [Marker] = []
    var boxes: [Box] = []
    var hottest: Marker?
    var coldest: Marker?
    var palette: Palette
    var rangeTopLabel: String
    var rangeBottomLabel: String
    var footer: String
}

/// Draws a thermal image with measurement overlays, color bar and footer into a
/// single bitmap using Core Graphics. Used for snapshots and video recording,
/// so the exported files look like what is on screen.
enum AnnotatedImageRenderer {
    private static let colorBarPanelWidth: CGFloat = 90
    private static let footerHeight: CGFloat = 30

    /// Output size for a given thermal image size. Always even, as H.264 requires.
    static func outputSize(imageWidth: Int, imageHeight: Int, scale: Int) -> CGSize {
        let width = CGFloat(imageWidth * scale) + colorBarPanelWidth
        let height = CGFloat(imageHeight * scale) + footerHeight
        return CGSize(width: (width / 2).rounded(.up) * 2, height: (height / 2).rounded(.up) * 2)
    }

    static func render(_ scene: AnnotationScene, scale: Int) -> CGImage? {
        let image = scene.thermalImage
        let size = outputSize(imageWidth: image.width, imageHeight: image.height, scale: scale)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Work in a top-left coordinate system like the screen.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let imageRect = CGRect(x: 0, y: 0, width: CGFloat(image.width * scale), height: CGFloat(image.height * scale))
        context.interpolationQuality = scene.smoothInterpolation ? .high : .none
        drawImage(image, in: imageRect, context: context)

        let pixelSize = CGFloat(scale)
        func center(of point: PixelPoint) -> CGPoint {
            CGPoint(x: (CGFloat(point.x) + 0.5) * pixelSize, y: (CGFloat(point.y) + 0.5) * pixelSize)
        }

        // Keep labels inside the image area.
        func drawLabel(_ text: String, at origin: CGPoint, anchorBottom: Bool, context: CGContext) {
            Self.drawLabel(text, at: origin, anchorBottom: anchorBottom, bounds: imageRect, context: context)
        }

        for box in scene.boxes {
            let rect = CGRect(x: CGFloat(box.rect.x) * pixelSize, y: CGFloat(box.rect.y) * pixelSize,
                              width: CGFloat(box.rect.width) * pixelSize, height: CGFloat(box.rect.height) * pixelSize)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(1.5)
            context.stroke(rect)
            drawLabel(box.text, at: CGPoint(x: rect.minX, y: rect.minY - 2), anchorBottom: true, context: context)
        }

        if let hottest = scene.hottest {
            drawMarker(at: center(of: hottest.point), color: CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1), context: context)
            drawLabel(hottest.text, at: center(of: hottest.point).offsetBy(dx: 10, dy: -10), anchorBottom: true, context: context)
        }
        if let coldest = scene.coldest {
            drawMarker(at: center(of: coldest.point), color: CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 1), context: context)
            drawLabel(coldest.text, at: center(of: coldest.point).offsetBy(dx: 10, dy: -10), anchorBottom: true, context: context)
        }

        for spot in scene.spots {
            drawCrosshair(at: center(of: spot.point), context: context)
            drawLabel(spot.text, at: center(of: spot.point).offsetBy(dx: 10, dy: -10), anchorBottom: true, context: context)
        }

        drawColorBar(scene, panel: CGRect(x: imageRect.maxX, y: 0, width: size.width - imageRect.maxX, height: imageRect.height),
                     context: context)
        drawText(scene.footer, at: CGPoint(x: 8, y: imageRect.maxY + 20), size: 12,
                 color: CGColor(gray: 0.85, alpha: 1), context: context)

        return context.makeImage()
    }

    // MARK: Drawing helpers

    /// Draws an image into a flipped context without turning it upside down.
    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawCrosshair(at point: CGPoint, context: CGContext) {
        for (color, width) in [(CGColor(gray: 0, alpha: 0.8), 3.0), (CGColor(gray: 1, alpha: 1), 1.5)] {
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.strokeEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
            context.move(to: CGPoint(x: point.x - 11, y: point.y)); context.addLine(to: CGPoint(x: point.x - 6, y: point.y))
            context.move(to: CGPoint(x: point.x + 6, y: point.y)); context.addLine(to: CGPoint(x: point.x + 11, y: point.y))
            context.move(to: CGPoint(x: point.x, y: point.y - 11)); context.addLine(to: CGPoint(x: point.x, y: point.y - 6))
            context.move(to: CGPoint(x: point.x, y: point.y + 6)); context.addLine(to: CGPoint(x: point.x, y: point.y + 11))
            context.strokePath()
        }
    }

    private static func drawMarker(at point: CGPoint, color: CGColor, context: CGContext) {
        let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
        context.setFillColor(color)
        context.fillEllipse(in: rect)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect)
    }

    /// Text on a dark rounded background, readable on any palette.
    private static func drawLabel(_ text: String, at origin: CGPoint, anchorBottom: Bool, bounds: CGRect, context: CGContext) {
        let line = makeLine(text, size: 12, color: CGColor(gray: 1, alpha: 1))
        let textBounds = CTLineGetImageBounds(line, context)
        let padding: CGFloat = 4
        let width = textBounds.width + 2 * padding + 2
        let height = 12 + 2 * padding
        let top = anchorBottom ? origin.y - height : origin.y
        let background = CGRect(x: min(max(origin.x, bounds.minX + 2), bounds.maxX - width - 2),
                                y: min(max(top, bounds.minY + 2), bounds.maxY - height - 2),
                                width: width, height: height)

        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        context.addPath(CGPath(roundedRect: background, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        drawLine(line, at: CGPoint(x: background.minX + padding, y: background.maxY - padding - 2), context: context)
    }

    private static func drawColorBar(_ scene: AnnotationScene, panel: CGRect, context: CGContext) {
        let bar = CGRect(x: panel.minX + 16, y: panel.minY + 28, width: 18, height: panel.height - 56)
        let colors = scene.palette.colors
        let stripeHeight = bar.height / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            context.setFillColor(color.cgColor)
            // Index 0 (cold) at the bottom.
            let y = bar.maxY - CGFloat(index + 1) * stripeHeight
            context.fill(CGRect(x: bar.minX, y: y, width: bar.width, height: stripeHeight + 0.5))
        }
        let labelColor = CGColor(gray: 0.95, alpha: 1)
        drawText(scene.rangeTopLabel, at: CGPoint(x: panel.minX + 6, y: bar.minY - 10), size: 11, color: labelColor, context: context)
        drawText(scene.rangeBottomLabel, at: CGPoint(x: panel.minX + 6, y: bar.maxY + 18), size: 11, color: labelColor, context: context)
    }

    private static func drawText(_ text: String, at baseline: CGPoint, size: CGFloat, color: CGColor, context: CGContext) {
        drawLine(makeLine(text, size: size, color: color), at: baseline, context: context)
    }

    private static func makeLine(_ text: String, size: CGFloat, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Draws a text line with its baseline at `baseline` in the flipped context.
    private static func drawLine(_ line: CTLine, at baseline: CGPoint, context: CGContext) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = baseline
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
