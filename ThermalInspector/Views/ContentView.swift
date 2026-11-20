import SwiftUI

/// The main screen: image with color bar, history chart, status bar, and the
/// settings sidebar (inspector). On iPhone the inspector appears as a sheet.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showInspector = false
    @State private var showAppSettings = false
    #else
    @State private var showInspector = true
    #endif
    @State private var showHistory = true

    var body: some View {
        #if os(macOS)
        mainContent
            .toolbar { macToolbar }
            .navigationTitle("Thermal Inspector")
        #else
        NavigationStack {
            mainContent
                .toolbar { iOSToolbar }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showAppSettings) {
            PreferencesView()
        }
        #endif
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ThermalImageView()
                    #if os(iOS)
                    // On iOS the tools float on the image and can be dragged out of the way.
                    .overlay { FloatingToolPicker() }
                    #endif
                ColorBarView()
                    .frame(width: isCompact ? 56 : 78)
            }
            .background(Color.black)

            if showHistory {
                Divider()
                HistoryChartView()
                    .frame(height: isCompact ? 160 : 190)
            }

            Divider()
            StatusBarView()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 290, ideal: 320, max: 420)
        }
    }

    /// iPhone in portrait (and other narrow layouts).
    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    // MARK: - Toolbar building blocks (shared by macOS and iOS)

    #if os(macOS)
    /// On iOS the tools float on the image instead (`FloatingToolPicker`).
    private var toolPicker: some View {
        @Bindable var model = model
        return Picker("Tool", selection: $model.tool) {
            ForEach(MeasurementTool.allCases) { tool in
                Label(tool.name, systemImage: tool.systemImage).tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .help("Pointer: read temperatures and drag spots or boxes to move them · Spot: click to place · Box: drag to draw")
    }
    #endif

    private var freezeButton: some View {
        Button {
            model.isFrozen.toggle()
        } label: {
            Label(model.isFrozen ? LocalizedStringKey("Resume") : "Freeze",
                  systemImage: model.isFrozen ? "play.fill" : "pause.fill")
        }
        .help("Freeze image (⌘F)")
    }

    private var referenceButton: some View {
        Button {
            model.captureReference()
        } label: {
            Label("Reference", systemImage: "camera.metering.center.weighted")
        }
        .help("Capture a reference image for the difference view (⌘D)")
        .disabled(model.connectionState != .streaming)
    }

    private var differenceToggle: some View {
        @Bindable var model = model
        return Toggle(isOn: $model.showDifference) {
            Label("ΔT", systemImage: "plusminus")
        }
        .help("Show difference to the reference (⇧⌘D)")
        .disabled(model.referenceFrame == nil)
    }

    private var snapshotButton: some View {
        Button {
            model.saveSnapshot()
        } label: {
            Label("Snapshot", systemImage: "camera")
        }
        .help("Save snapshot: PNG + temperature data (⌘S)")
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            Label(model.isRecording ? LocalizedStringKey("Stop") : "Record",
                  systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                .foregroundStyle(model.isRecording ? .red : .primary)
        }
        .help("Start/stop video recording (⌘R)")
    }

    private var shutterButton: some View {
        Button {
            model.triggerShutter()
        } label: {
            Label("Shutter / Recalibrate", systemImage: "camera.aperture")
        }
        .help("Briefly closes the shutter and recalibrates the sensor. Helps against streaks and drift.")
        .disabled(model.connectionState != .streaming)
    }

    private var historyToggle: some View {
        Toggle(isOn: $showHistory) {
            Label("History", systemImage: "chart.xyaxis.line")
        }
        .help("Show/hide temperature history")
    }

    // MARK: - macOS toolbar

    #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { toolPicker }

        ToolbarItemGroup(placement: .primaryAction) {
            freezeButton
            referenceButton
            differenceToggle
            snapshotButton
            recordButton
            historyToggle
            Button {
                showInspector.toggle()
            } label: {
                Label("Settings", systemImage: "sidebar.right")
            }
            .help("Show/hide settings")
        }
    }
    #endif

    // MARK: - iOS toolbar

    #if os(iOS)
    /// The most used actions as buttons, everything else in a menu.
    @ToolbarContentBuilder
    private var iOSToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            freezeButton
            shutterButton
            snapshotButton
            if !isCompact {
                recordButton
                referenceButton
                differenceToggle
            }
            Button {
                showInspector.toggle()
            } label: {
                Label("Controls", systemImage: "slider.horizontal.3")
            }

            Menu {
                if isCompact {
                    recordButton
                    referenceButton
                    differenceToggle
                }
                historyToggle
                Divider()
                Button {
                    showAppSettings = true
                } label: {
                    Label("App Settings", systemImage: "gearshape")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
    #endif
}
