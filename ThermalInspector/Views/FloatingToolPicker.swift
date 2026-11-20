#if os(iOS)
import SwiftUI

/// The tool picker on iPhone/iPad: a small glass capsule floating on the image.
///
/// Tap a symbol to choose the tool. Drag the capsule to move it out of the way;
/// the position is remembered. It always stays inside the image area.
struct FloatingToolPicker: View {
    @Environment(AppModel.self) private var model

    /// Position of the capsule relative to the top leading corner, saved between launches.
    @AppStorage("toolPickerX") private var savedX = 12.0
    @AppStorage("toolPickerY") private var savedY = 12.0
    /// How far the capsule is currently being dragged.
    @GestureState private var dragTranslation = CGSize.zero
    @State private var pickerSize = CGSize(width: 160, height: 52)

    var body: some View {
        GeometryReader { container in
            let position = clamped(CGPoint(x: savedX + dragTranslation.width, y: savedY + dragTranslation.height),
                                   in: container.size)
            capsule
                .onGeometryChange(for: CGSize.self) { $0.size } action: { pickerSize = $0 }
                .offset(x: position.x, y: position.y)
                // High priority: the buttons and the interactive glass would otherwise take
                // the touch. Taps still reach the buttons – dragging starts only after 8 pt.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8)
                        .updating($dragTranslation) { drag, state, _ in state = drag.translation }
                        .onEnded { drag in
                            let end = clamped(CGPoint(x: savedX + drag.translation.width,
                                                      y: savedY + drag.translation.height), in: container.size)
                            savedX = end.x
                            savedY = end.y
                        }
                )
        }
    }

    private var capsule: some View {
        HStack(spacing: 2) {
            // Grip, so it is clear the capsule can be moved.
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)

            ForEach(MeasurementTool.allCases) { tool in
                toolButton(tool)
            }
        }
        .padding(4)
        .glassCapsule()
    }

    private func toolButton(_ tool: MeasurementTool) -> some View {
        let isSelected = model.tool == tool
        return Button {
            model.tool = tool
        } label: {
            Image(systemName: tool.systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 42, height: 42)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy, value: isSelected)
    }

    /// Keeps the whole capsule inside the container.
    private func clamped(_ point: CGPoint, in container: CGSize) -> CGPoint {
        let margin: CGFloat = 4
        return CGPoint(
            x: min(max(point.x, margin), max(container.width - pickerSize.width - margin, margin)),
            y: min(max(point.y, margin), max(container.height - pickerSize.height - margin, margin))
        )
    }
}

private extension View {
    /// Liquid Glass on iOS 26 and later, frosted material before.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }
    }
}
#endif
