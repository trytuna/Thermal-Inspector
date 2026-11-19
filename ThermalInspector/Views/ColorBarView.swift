import SwiftUI

/// Vertical color scale next to the image with the current range.
struct ColorBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.isShowingDifference ? Palette.difference : model.palette
        let range = model.displayRange

        VStack(spacing: 6) {
            // The detail image has no temperature scale – only show which end is bright.
            Text(verbatim: model.isShowingDetail ? String(localized: "Detail") : model.formatted(range.upperBound))
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette.verticalGradient)

                    // Mark the isotherm threshold on the scale.
                    if model.isothermEnabled, !model.isShowingDifference, !model.isShowingDetail,
                       range.contains(model.isothermThreshold) {
                        let fraction = (model.isothermThreshold - range.lowerBound) / (range.upperBound - range.lowerBound)
                        Rectangle()
                            .fill(.white)
                            .frame(height: 2)
                            .offset(y: -CGFloat(fraction) * geometry.size.height)
                    }
                }
            }
            .frame(width: 18)
            Text(verbatim: model.isShowingDetail ? " " : model.formatted(range.lowerBound))
            if model.rangeMode == .manual, !model.isShowingDifference {
                Image(systemName: "lock.fill")
                    .help("Manual range")
            }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.vertical, 12)
    }
}
