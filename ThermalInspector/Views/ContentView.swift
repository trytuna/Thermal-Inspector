import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @State private var showHistory = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ThermalImageView()
                ColorBarView()
                    .frame(width: 78)
            }
            .background(Color.black)

            if showHistory {
                Divider()
                HistoryChartView()
                    .frame(height: 190)
            }

            Divider()
            StatusBarView()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 290, ideal: 320, max: 420)
        }
        .toolbar { toolbarContent }
        .navigationTitle("Thermal Inspector")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model

        ToolbarItem(placement: .navigation) {
            Picker("Tool", selection: $model.tool) {
                ForEach(MeasurementTool.allCases) { tool in
                    Label(tool.name, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .help("Pointer: read temperatures and drag spots or boxes to move them · Spot: click to place · Box: drag to draw")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.isFrozen.toggle()
            } label: {
                Label(model.isFrozen ? LocalizedStringKey("Resume") : "Freeze",
                      systemImage: model.isFrozen ? "play.fill" : "pause.fill")
            }
            .help("Freeze image (⌘F)")

            Button {
                model.captureReference()
            } label: {
                Label("Reference", systemImage: "camera.metering.center.weighted")
            }
            .help("Capture a reference image for the difference view (⌘D)")
            .disabled(model.connectionState != .streaming)

            Toggle(isOn: $model.showDifference) {
                Label("ΔT", systemImage: "plusminus")
            }
            .help("Show difference to the reference (⇧⌘D)")
            .disabled(model.referenceFrame == nil)

            Button {
                model.saveSnapshot()
            } label: {
                Label("Snapshot", systemImage: "camera")
            }
            .help("Save snapshot: PNG + temperature data (⌘S)")

            Button {
                model.toggleRecording()
            } label: {
                Label(model.isRecording ? LocalizedStringKey("Stop") : "Record",
                      systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(model.isRecording ? .red : .primary)
            }
            .help("Start/stop video recording (⌘R)")

            Toggle(isOn: $showHistory) {
                Label("History", systemImage: "chart.xyaxis.line")
            }
            .help("Show/hide temperature history")

            Button {
                showInspector.toggle()
            } label: {
                Label("Settings", systemImage: "sidebar.right")
            }
            .help("Show/hide settings")
        }
    }
}
