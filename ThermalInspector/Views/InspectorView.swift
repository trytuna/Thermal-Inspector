import SwiftUI

/// The settings sidebar.
struct InspectorView: View {
    var body: some View {
        Form {
            CameraSection()
            DisplaySection()
            RadiometrySection()
            DifferenceSection()
            MeasurementListSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Camera

private struct CameraSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section("Camera") {
            Picker("Source", selection: $model.cameraSource) {
                ForEach(CameraSource.allCases) { Text(verbatim: $0.label).tag($0) }
            }

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(model.connectionState.color).frame(width: 8, height: 8)
                    Text(model.connectionState.description)
                        .multilineTextAlignment(.trailing)
                }
            }

            if let info = model.cameraInfo {
                LabeledContent("Model", value: info.modelName)
                LabeledContent("Firmware", value: info.firmwareVersion)
                if !info.serialNumber.isEmpty { LabeledContent("Serial Number", value: info.serialNumber) }
            }

            Picker("Range", selection: $model.gainMode) {
                Text("−20 … 150 °C (sensitive)").tag(GainMode.high)
                Text(verbatim: "100 … 600 °C").tag(GainMode.low)
            }

            if model.connectionState == .streaming {
                CalibrationStatusView()
            }

            Button("Shutter / Recalibrate (NUC)") { model.triggerShutter() }
                .disabled(model.connectionState != .streaming)
                .help("Briefly closes the shutter and recalibrates the sensor. Helps against streaks and drift.")

            Toggle("Burn-in protection", isOn: $model.burnProtection)
                .help("The camera closes its shutter when it sees the sun or a laser, to protect the sensor. The official app turns this on.")

            Toggle("Automatic shutter", isOn: $model.automaticShutter)
            if !model.automaticShutter {
                Text("The camera no longer recalibrates itself every 90 seconds, so the image does not jump during a measurement. Readings drift slowly instead – trigger the shutter by hand before measuring. Switching reconnects the camera for a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// When the camera last recalibrated itself and how much it had drifted.
private struct CalibrationStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calibration = model.calibration

        LabeledContent("Calibration") {
            if let date = calibration.lastCalibration, let correction = calibration.lastCorrection {
                // Refresh every second so "x seconds ago" stays current.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(date.formatted(.relative(presentation: .named)))
                        Text("correction \(TemperatureFormat.difference(correction))")
                            .font(.caption)
                            .foregroundStyle(calibration.isStable == true ? Color.secondary : Color.orange)
                    }
                }
            } else {
                Text("not observed yet")
                    .foregroundStyle(.secondary)
            }
        }
        .help("The camera recalibrates itself about every 90 seconds and corrects its drift. The size of the correction shows how much the readings had drifted.")

        if calibration.isStable == false {
            Label("The camera is still drifting (e.g. warming up). Readings can be off by several kelvin – trigger the shutter right before measuring.",
                  systemImage: "thermometer.medium")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Display

private struct DisplaySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section("Display") {
            Picker("Image", selection: $model.imageMode) {
                ForEach(ImageMode.allCases) { Text(verbatim: $0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Detail: the camera's own contrast-enhanced image – shows component outlines better. Measurements still use the temperatures.")

            if model.imageMode == .detail {
                // These change the camera's own image only, never the temperatures.
                ForEach(ImageAdjustment.allCases) { adjustment in
                    ImageAdjustmentSlider(adjustment: adjustment)
                }
            }

            Picker("Palette", selection: $model.palette) {
                ForEach(Palette.selectable) { palette in
                    Text(verbatim: palette.name).tag(palette)
                }
            }

            Picker("Temperature Range", selection: $model.rangeMode) {
                ForEach(RangeMode.allCases) { Text(verbatim: $0.name).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.rangeMode == .manual {
                TemperatureSlider(title: "Minimum", value: $model.manualMinimum, range: model.sensorRange)
                TemperatureSlider(title: "Maximum", value: $model.manualMaximum, range: model.sensorRange)
            } else {
                Button("Lock Current Range") { model.lockCurrentRange() }
                    .help("Keeps the color scale fixed so images stay comparable")
            }

            Toggle("Isotherm (color hot areas only)", isOn: $model.isothermEnabled)
            if model.isothermEnabled {
                TemperatureSlider(title: "Above", value: $model.isothermThreshold, range: model.sensorRange)
            }

            Toggle("Max/min markers", isOn: $model.showHotAndColdMarkers)
            Toggle("Smooth interpolation", isOn: $model.smoothInterpolation)

            LabeledContent("Orientation") {
                HStack(spacing: 4) {
                    Button { model.orientation.rotateCounterClockwise() } label: { Image(systemName: "rotate.left") }
                        .help("Rotate 90° counterclockwise")
                    Button { model.orientation.rotateClockwise() } label: { Image(systemName: "rotate.right") }
                        .help("Rotate 90° clockwise")
                    Toggle(isOn: $model.orientation.mirroredHorizontally) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .help("Mirror horizontally")
                    Toggle(isOn: $model.orientation.mirroredVertically) {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                    .help("Mirror vertically")
                }
                .toggleStyle(.button)
            }
        }
    }
}

// MARK: - Radiometry

private struct RadiometrySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section {
            LabeledContent("Emissivity ε") {
                HStack {
                    Slider(value: $model.radiometry.emissivity, in: 0.05...1.0, step: 0.01)
                    Text(verbatim: TemperatureFormat.emissivity(model.radiometry.emissivity))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Menu("Choose Material …") {
                ForEach(EmissivityPreset.all) { preset in
                    Button {
                        model.radiometry.emissivity = preset.emissivity
                    } label: {
                        Text(verbatim: "\(preset.name)  (\(TemperatureFormat.emissivity(preset.emissivity)))")
                    }
                }
            }

            if model.radiometry.emissivity < 0.5 {
                Label("Readings on bare metal are unreliable. Better: stick a piece of matte electrical tape on it and use ε = 0.95.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TemperatureSlider(title: "Reflected Temp.", value: $model.radiometry.reflectedTemperature, range: -10...60)

            Picker("Noise Filter", selection: $model.averagedFrames) {
                Text("Off").tag(1)
                Text("\(2) frames").tag(2)
                Text("\(4) frames").tag(4)
                Text("\(8) frames").tag(8)
                Text("\(16) frames").tag(16)
            }
            .help("Averages several frames – reveals small temperature differences but delays motion")
        } header: {
            Text("Measurement")
        }
    }
}

// MARK: - Difference

private struct DifferenceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Section {
            Text("Capture the reference with the board **powered off**, then power it on: the difference image shows only the heating – ideal for finding shorts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let progress = model.referenceCaptureProgress {
                ProgressView("Capturing reference …", value: progress)
            } else {
                HStack {
                    Button(model.referenceFrame == nil ? LocalizedStringKey("Capture Reference") : "Renew Reference") {
                        model.captureReference()
                    }
                    .disabled(model.connectionState != .streaming)

                    if model.referenceFrame != nil {
                        Button("Discard", role: .destructive) { model.discardReference() }
                    }
                }
            }

            if model.referenceIsOutdated {
                Label("The camera recalibrated since the reference was taken. The difference image may be shifted – capture the reference again.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Show difference image (ΔT)", isOn: $model.showDifference)
                .disabled(model.referenceFrame == nil)
        } header: {
            Text("Difference Image")
        }
    }
}

// MARK: - Measurement list

private struct MeasurementListSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Measurements") {
            if model.spots.isEmpty && model.boxes.isEmpty {
                Text("Choose the “Spot” or “Box” tool and click or drag in the image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.spots) { spot in
                HStack {
                    Text(spot.label).bold()
                    Spacer()
                    Text(model.displayValue(at: spot.point).map(model.formatted) ?? "–")
                        .monospacedDigit()
                    RemoveButton { model.removeSpot(spot) }
                }
            }

            ForEach(model.boxes) { box in
                HStack(alignment: .firstTextBaseline) {
                    Text(box.label).bold()
                    Spacer()
                    if let statistics = model.statistics(for: box) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: model.maximumLabel(statistics.maximum))
                            Text("avg \(model.formatted(statistics.mean))  min \(model.formatted(statistics.minimum))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                    RemoveButton { model.removeBox(box) }
                }
            }

            if !model.spots.isEmpty || !model.boxes.isEmpty {
                Button("Remove All", role: .destructive) { model.clearMeasurements() }
            }
        }
    }
}

// MARK: - Small building blocks

/// A 0 … 100 slider for a setting of the camera's own grayscale image.
private struct ImageAdjustmentSlider: View {
    @Environment(AppModel.self) private var model
    let adjustment: ImageAdjustment

    private var title: LocalizedStringKey {
        switch adjustment {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .detailEnhancement: "Detail Enhancement"
        case .noiseReduction: "Noise Reduction"
        }
    }

    var body: some View {
        let value = model.imageAdjustment(adjustment)
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(value ?? 50) },
                                      set: { model.setImageAdjustment(adjustment, to: Int($0.rounded())) }),
                       in: 0...100)
                // Until it is changed, the camera keeps its own value, which cannot be read.
                Group {
                    if let value { Text(verbatim: "\(value)") } else { Text("Camera") }
                }
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            }
        }
        .help("Changes only the camera's own image in the Detail view, not the temperatures.")
    }
}

/// A slider with a numeric field for a temperature in °C.
private struct TemperatureSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                TextField(title, value: $value, format: .number.precision(.fractionLength(1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text(verbatim: "°C")
            }
        }
    }
}

private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}
