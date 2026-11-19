import Charts
import SwiftUI

/// Temperature over time for the frame maximum and all measurement points.
struct HistoryChartView: View {
    @Environment(AppModel.self) private var model

    private let windows: [(label: String, seconds: TimeInterval)] = [
        ("30 s", 30), ("1 min", 60), ("5 min", 300), ("15 min", 900),
    ]

    var body: some View {
        @Bindable var model = model
        let points = model.history.chartPoints(lastSeconds: model.historyWindow)
        let calibrations = model.history.calibrationTimes(lastSeconds: model.historyWindow)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Temperature History")
                    .font(.headline)
                Spacer()
                Picker("Time Span", selection: $model.historyWindow) {
                    ForEach(windows, id: \.seconds) { Text(verbatim: $0.label).tag($0.seconds) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Button("Export CSV") { model.exportHistory() }
                    .disabled(model.history.isEmpty)
                Button("Clear") { model.clearHistory() }
            }

            if points.isEmpty {
                Text("No data yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Temperature", point.value)
                        )
                        .foregroundStyle(by: .value("Measurement", point.series))
                        .interpolationMethod(.monotone)
                    }
                    // Jumps in the curves at these lines come from the camera's recalibration.
                    ForEach(calibrations, id: \.self) { time in
                        RuleMark(x: .value("Calibration", time))
                            .foregroundStyle(.gray.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel { Text(verbatim: "°C") }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    }
                }
                .chartLegend(position: .trailing, alignment: .top)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
