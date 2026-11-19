import Foundation

/// Records temperatures over time, e.g. to watch a board warm up after power-on.
struct TemperatureHistory {
    /// One point in time with a value per series ("Max", "P1", "B1 max", …).
    struct Sample {
        let time: Date
        let values: [String: Float]
    }

    /// One value of one series, the shape Swift Charts wants.
    struct ChartPoint: Identifiable {
        let id: Int
        let time: Date
        let series: String
        let value: Float
    }

    /// Samples older than this are dropped.
    var maximumAge: TimeInterval = 30 * 60
    /// We record at most this often, regardless of the camera frame rate.
    var sampleInterval: TimeInterval = 0.2

    private(set) var samples: [Sample] = []
    /// When the camera recalibrated itself – shown as markers in the chart.
    private(set) var calibrationTimes: [Date] = []

    var isEmpty: Bool { samples.isEmpty }

    mutating func record(_ values: [String: Float], at time: Date = Date()) {
        if let last = samples.last, time.timeIntervalSince(last.time) < sampleInterval { return }
        samples.append(Sample(time: time, values: values))

        let cutoff = time.addingTimeInterval(-maximumAge)
        if let firstToKeep = samples.firstIndex(where: { $0.time >= cutoff }), firstToKeep > 0 {
            samples.removeFirst(firstToKeep)
        }
        calibrationTimes.removeAll { $0 < cutoff }
    }

    mutating func markCalibration(at time: Date = Date()) {
        calibrationTimes.append(time)
    }

    mutating func clear() {
        samples.removeAll()
        calibrationTimes.removeAll()
    }

    /// Calibration times within the last `window` seconds of the history.
    func calibrationTimes(lastSeconds window: TimeInterval) -> [Date] {
        guard let end = samples.last?.time else { return [] }
        return calibrationTimes.filter { $0 >= end.addingTimeInterval(-window) }
    }

    /// Chart points of the last `window` seconds, thinned out to at most
    /// `maximumSamples` samples so the chart stays fast.
    func chartPoints(lastSeconds window: TimeInterval, maximumSamples: Int = 300) -> [ChartPoint] {
        guard let end = samples.last?.time else { return [] }
        let start = end.addingTimeInterval(-window)
        let visible = samples.drop { $0.time < start }
        let step = max(visible.count / maximumSamples, 1)

        var points: [ChartPoint] = []
        for (offset, sample) in visible.enumerated() where offset % step == 0 {
            for (series, value) in sample.values.sorted(by: { $0.key < $1.key }) {
                points.append(ChartPoint(id: points.count, time: sample.time, series: series, value: value))
            }
        }
        return points
    }

    /// All samples as CSV: one row per sample, one column per series.
    func csv() -> String {
        let seriesNames = Set(samples.flatMap { $0.values.keys }).sorted()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startTime = samples.first?.time ?? Date()

        var lines = [(["time", "seconds"] + seriesNames.map { "\($0) [°C]" }).joined(separator: ",")]
        for sample in samples {
            var columns = [formatter.string(from: sample.time),
                           String(format: "%.2f", sample.time.timeIntervalSince(startTime))]
            columns += seriesNames.map { name in
                sample.values[name].map { String(format: "%.2f", $0) } ?? ""
            }
            lines.append(columns.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
