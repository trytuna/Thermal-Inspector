import SwiftUI

/// Bottom bar: connection, frame rate, cursor temperature, frame statistics and messages.
struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle().fill(model.connectionState.color).frame(width: 8, height: 8)
                Text(model.connectionState == .streaming ? String(format: "%.0f fps", model.framesPerSecond)
                                                         : model.connectionState.description)
                    .lineLimit(1)
            }

            if model.calibration.isStable == false, let correction = model.calibration.lastCorrection {
                Label("Drifting (\(TemperatureFormat.difference(correction)))", systemImage: "thermometer.medium")
                    .foregroundStyle(.orange)
                    .help("The last automatic calibration had to correct the image by this amount. Trigger the shutter right before measuring.")
            }

            if model.isFrozen {
                Label("Frozen", systemImage: "pause.fill")
                    .foregroundStyle(.orange)
            }

            if let recorder = model.videoRecorder {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Label(Duration.seconds(recorder.duration).formatted(.time(pattern: .minuteSecond)),
                          systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let message = model.statusMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let url = model.lastSavedURL {
                    Button("Show in Finder") { SnapshotExporter.revealInFinder(url) }
                        .buttonStyle(.link)
                }
            }

            Spacer()

            if let hover = model.hoverPoint, let value = model.displayValue(at: hover) {
                Text("Cursor (\(hover.x), \(hover.y)): \(model.formatted(value))")
            }

            if let statistics = model.displayStatistics {
                Text("min \(model.formatted(statistics.minimum))   avg \(model.formatted(statistics.mean))   max \(model.formatted(statistics.maximum))")
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
