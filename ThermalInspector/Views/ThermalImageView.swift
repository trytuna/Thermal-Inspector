import SwiftUI

/// Maps between view coordinates and thermal image pixels for an image that
/// is scaled to fit (aspect fit) into a container.
struct ImageLayout {
    let pixelWidth: Int
    let pixelHeight: Int
    /// Where the image is drawn inside the container.
    let rect: CGRect

    init(container: CGSize, pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        let scale = min(container.width / CGFloat(pixelWidth), container.height / CGFloat(pixelHeight))
        let size = CGSize(width: CGFloat(pixelWidth) * scale, height: CGFloat(pixelHeight) * scale)
        rect = CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private var pixelSize: CGFloat { rect.width / CGFloat(pixelWidth) }

    /// Center of a pixel in view coordinates.
    func viewPoint(for pixel: PixelPoint) -> CGPoint {
        CGPoint(x: rect.minX + (CGFloat(pixel.x) + 0.5) * pixelSize,
                y: rect.minY + (CGFloat(pixel.y) + 0.5) * pixelSize)
    }

    func viewRect(for pixels: PixelRect) -> CGRect {
        CGRect(x: rect.minX + CGFloat(pixels.x) * pixelSize, y: rect.minY + CGFloat(pixels.y) * pixelSize,
               width: CGFloat(pixels.width) * pixelSize, height: CGFloat(pixels.height) * pixelSize)
    }

    /// The pixel under a view point, or nil outside the image.
    func pixel(at point: CGPoint) -> PixelPoint? {
        guard rect.contains(point) else { return nil }
        return clampedPixel(at: point)
    }

    /// The nearest pixel to a view point, even outside the image.
    func clampedPixel(at point: CGPoint) -> PixelPoint {
        clamped(PixelPoint(x: Int((point.x - rect.minX) / pixelSize), y: Int((point.y - rect.minY) / pixelSize)))
    }

    /// Moves a pixel position into the image if it is outside.
    func clamped(_ pixel: PixelPoint) -> PixelPoint {
        PixelPoint(x: min(max(pixel.x, 0), pixelWidth - 1), y: min(max(pixel.y, 0), pixelHeight - 1))
    }
}

/// The live thermal image with measurement overlays and mouse interaction.
struct ThermalImageView: View {
    @Environment(AppModel.self) private var model
    /// The box currently being drawn with the box tool.
    @State private var draftBox: PixelRect?
    /// The measurement currently being moved with the pointer tool.
    @State private var movedMeasurement: MovedMeasurement?
    /// True while the mouse is over something that can be moved.
    @State private var isOverMovableMeasurement = false
    /// The image takes the keyboard focus at launch, so no text field in the
    /// sidebar is focused (and accidentally edited by typing).
    @FocusState private var isFocused: Bool

    /// A spot or box being dragged, with where it was when the drag started.
    private enum MovedMeasurement {
        case spot(id: SpotMeasurement.ID, start: PixelPoint)
        case box(id: BoxMeasurement.ID, start: PixelRect)
    }

    var body: some View {
        GeometryReader { geometry in
            if let image = model.image {
                let layout = ImageLayout(container: geometry.size, pixelWidth: image.width, pixelHeight: image.height)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(model.smoothInterpolation ? .high : .none)
                        .frame(width: layout.rect.width, height: layout.rect.height)
                        .offset(x: layout.rect.minX, y: layout.rect.minY)

                    MeasurementOverlay(layout: layout, draftBox: draftBox)
                        .allowsHitTesting(false)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        model.hoverPoint = layout.pixel(at: location)
                        isOverMovableMeasurement = model.tool == .inspect && measurement(at: location, layout: layout) != nil
                    case .ended:
                        model.hoverPoint = nil
                        isOverMovableMeasurement = false
                    }
                }
                #if os(macOS)
                .pointerStyle(movedMeasurement != nil ? .grabActive : isOverMovableMeasurement ? .grabIdle : nil)
                #endif
                .gesture(clickAndDragGesture(layout: layout))
                #if os(macOS)
                // On iOS a long press would compete with dragging measurements.
                .contextMenu { contextMenu }
                #endif
            } else {
                placeholder
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        // Take the keyboard focus at launch – also before the camera delivers an image.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
    }

    private func clickAndDragGesture(layout: ImageLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                model.hoverPoint = layout.pixel(at: drag.location)
                switch model.tool {
                case .inspect:
                    move(drag, layout: layout)
                case .box:
                    guard let start = layout.pixel(at: drag.startLocation) else { return }
                    draftBox = PixelRect(from: start, to: layout.clampedPixel(at: drag.location))
                case .spot:
                    break
                }
            }
            .onEnded { drag in
                #if os(iOS)
                // Touch has no hover: the readout is only shown while the finger is down.
                model.hoverPoint = nil
                #endif
                switch model.tool {
                case .inspect:
                    movedMeasurement = nil
                case .spot:
                    if let pixel = layout.pixel(at: drag.location) { model.addSpot(at: pixel) }
                case .box:
                    if let box = draftBox, box.width >= 2, box.height >= 2 { model.addBox(box) }
                    draftBox = nil
                }
            }
    }

    /// Moves the spot or box that was grabbed at the start of the drag.
    private func move(_ drag: DragGesture.Value, layout: ImageLayout) {
        if movedMeasurement == nil {
            movedMeasurement = measurement(at: drag.startLocation, layout: layout)
        }
        // Move by the distance the mouse travelled, in image pixels.
        let start = layout.clampedPixel(at: drag.startLocation)
        let current = layout.clampedPixel(at: drag.location)
        let dx = current.x - start.x, dy = current.y - start.y

        switch movedMeasurement {
        case let .spot(id, startPoint):
            model.moveSpot(id: id, to: layout.clamped(PixelPoint(x: startPoint.x + dx, y: startPoint.y + dy)))
        case let .box(id, startRect):
            model.moveBox(id: id, to: PixelPoint(x: startRect.x + dx, y: startRect.y + dy))
        case nil:
            break
        }
    }

    /// The spot or box under a view point. Spots win over boxes, the most recent one wins.
    private func measurement(at location: CGPoint, layout: ImageLayout) -> MovedMeasurement? {
        let grabRadius: CGFloat = 12
        if let spot = model.spots.last(where: { spot in
            let center = layout.viewPoint(for: spot.point)
            return hypot(center.x - location.x, center.y - location.y) <= grabRadius
        }) {
            return .spot(id: spot.id, start: spot.point)
        }
        if let box = model.boxes.last(where: { layout.viewRect(for: $0.rect).insetBy(dx: -4, dy: -4).contains(location) }) {
            return .box(id: box.id, start: box.rect)
        }
        return nil
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Remove All Measurements") { model.clearMeasurements() }
        Button(model.isFrozen ? LocalizedStringKey("Resume Live Image") : "Freeze Image") { model.isFrozen.toggle() }
        Button("Save Snapshot") { model.saveSnapshot() }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if model.connectionState == .connecting {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 48))
            }
            Text(model.connectionState.description)
                .font(.title3)
            if model.cameraSource != .simulation {
                Button("Try without a camera (demo)") { model.cameraSource = .simulation }
                    #if os(macOS)
                    .buttonStyle(.link)
                    #else
                    .buttonStyle(.borderless)
                    #endif
            }
        }
        .multilineTextAlignment(.center)
        // Light colors: the placeholder sits on the black image background.
        .foregroundStyle(.white.opacity(0.75))
        .tint(.cyan)
        .padding()
    }
}

/// Draws spots, boxes, hot/cold markers and the cursor readout on top of the image.
private struct MeasurementOverlay: View {
    @Environment(AppModel.self) private var model
    let layout: ImageLayout
    let draftBox: PixelRect?

    var body: some View {
        Canvas { context, _ in
            for box in model.boxes {
                let rect = layout.viewRect(for: box.rect)
                context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
                if let statistics = model.statistics(for: box) {
                    let text = model.boxLabel(box, statistics)
                    drawLabel(text, at: CGPoint(x: rect.minX, y: rect.minY - 3), anchor: .bottomLeading, in: &context)
                    drawDot(at: layout.viewPoint(for: statistics.hottest), color: .red, radius: 3, in: &context)
                }
            }

            if let draftBox {
                context.stroke(Path(layout.viewRect(for: draftBox)), with: .color(.white),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }

            if model.showHotAndColdMarkers, let statistics = model.displayStatistics {
                let hot = layout.viewPoint(for: statistics.hottest)
                drawDot(at: hot, color: .red, radius: 5, in: &context)
                drawLabel(model.maximumLabel(statistics.maximum), at: hot + CGPoint(x: 9, y: -9), anchor: .bottomLeading, in: &context)

                let cold = layout.viewPoint(for: statistics.coldest)
                drawDot(at: cold, color: .blue, radius: 5, in: &context)
                drawLabel(model.minimumLabel(statistics.minimum), at: cold + CGPoint(x: 9, y: -9), anchor: .bottomLeading, in: &context)
            }

            for spot in model.spots {
                let center = layout.viewPoint(for: spot.point)
                drawCrosshair(at: center, in: &context)
                if let value = model.displayValue(at: spot.point) {
                    drawLabel("\(spot.label)  \(model.formatted(value))", at: center + CGPoint(x: 10, y: -10),
                              anchor: .bottomLeading, in: &context)
                }
            }

            if let hover = model.hoverPoint, let value = model.displayValue(at: hover) {
                var text = model.formatted(value)
                if model.isShowingDifference, let absolute = model.absoluteValue(at: hover) {
                    text += "  (\(TemperatureFormat.absolute(absolute)))"
                }
                let point = layout.viewPoint(for: hover)
                #if os(iOS)
                // Above the finger, so it is not covered while touching the image.
                drawLabel(text, at: point + CGPoint(x: 0, y: -44), anchor: .bottom, in: &context)
                #else
                drawLabel(text, at: point + CGPoint(x: 14, y: 14), anchor: .topLeading, in: &context)
                #endif
            }
        }
    }

    private func drawCrosshair(at center: CGPoint, in context: inout GraphicsContext) {
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        for (from, to) in [((-11.0, 0.0), (-6.0, 0.0)), ((6, 0), (11, 0)), ((0, -11), (0, -6)), ((0, 6), (0, 11))] {
            path.move(to: center + CGPoint(x: from.0, y: from.1))
            path.addLine(to: center + CGPoint(x: to.0, y: to.1))
        }
        context.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 3)
        context.stroke(path, with: .color(.white), lineWidth: 1.5)
    }

    private func drawDot(at center: CGPoint, color: Color, radius: CGFloat, in context: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        context.fill(circle, with: .color(color))
        context.stroke(circle, with: .color(.white), lineWidth: 1.5)
    }

    /// Text on a dark rounded background, readable on any palette.
    private func drawLabel(_ string: String, at point: CGPoint, anchor: UnitPoint, in context: inout GraphicsContext) {
        let text = context.resolve(
            Text(string).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        )
        let size = text.measure(in: CGSize(width: 400, height: 40))
        let padding = CGSize(width: 5, height: 2)
        let boxSize = CGSize(width: size.width + 2 * padding.width, height: size.height + 2 * padding.height)
        var origin = CGPoint(x: point.x - anchor.x * boxSize.width, y: point.y - anchor.y * boxSize.height)
        // Keep labels inside the image, e.g. for a hot spot at the very edge.
        origin.x = min(max(origin.x, layout.rect.minX + 2), layout.rect.maxX - boxSize.width - 2)
        origin.y = min(max(origin.y, layout.rect.minY + 2), layout.rect.maxY - boxSize.height - 2)
        let box = CGRect(origin: origin, size: boxSize)

        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.65)))
        context.draw(text, at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height), anchor: .topLeading)
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}
