import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The app settings: a Settings window with tabs on macOS (⌘,),
/// a sheet with a list of pages on iPhone/iPad.
struct PreferencesView: View {
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPreferences() }
            Tab("Export", systemImage: "square.and.arrow.up") { ExportPreferences() }
            Tab("History", systemImage: "chart.xyaxis.line") { HistoryPreferences() }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        #else
        NavigationStack {
            List {
                NavigationLink { GeneralPreferences().navigationTitle("General") } label: {
                    Label("General", systemImage: "gearshape")
                }
                NavigationLink { ExportPreferences().navigationTitle("Export") } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                NavigationLink { HistoryPreferences().navigationTitle("History") } label: {
                    Label("History", systemImage: "chart.xyaxis.line")
                }
            }
            .navigationTitle("App Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        #endif
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var preferences = model.preferences
        @Bindable var model = model

        Form {
            Section {
                #if os(macOS)
                Picker("Language", selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.name).tag($0) }
                }
                if preferences.needsRestartForLanguage {
                    HStack {
                        Text("The new language is used after restarting the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { preferences.relaunch() }
                    }
                }
                #else
                // On iOS every app's language is chosen in the system Settings app.
                Button("Language …") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                #endif
            }

            Section {
                Picker("Camera", selection: $model.cameraSource) {
                    ForEach(CameraSource.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Toggle("Remember settings", isOn: $preferences.rememberSettings)
                Text("Restores palette, temperature range, emissivity, orientation, noise filter and measuring range on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset All Settings …", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetAllSettings() }
        } message: {
            Text("Saved snapshots and videos are not affected.")
        }
    }
}

// MARK: - Export

private struct ExportPreferences: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            #if os(macOS)
            Section {
                LabeledContent("Output folder") {
                    HStack {
                        Text(verbatim: preferences.outputFolder.abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(preferences.outputFolder.path)
                        Button("Choose …") { preferences.chooseOutputFolder() }
                        Button {
                            model.openOutputFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Open in Finder")
                    }
                }
            }

            #else
            Section {
                Text("Snapshots, videos and history exports are saved in the Files app under “On My iPhone/iPad → Thermal Inspector”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            Section("Snapshot") {
                LabeledContent("Files") {
                    VStack(alignment: .leading) {
                        Toggle("Image with measurements (PNG)", isOn: .constant(true))
                            .disabled(true)
                        Toggle("Temperature data of every pixel (CSV)", isOn: $preferences.saveTemperatureCSV)
                        Toggle("Settings and measurements (JSON)", isOn: $preferences.saveMetadataJSON)
                    }
                }
                ScalePicker(title: "Image size", scale: $preferences.snapshotScale)
            }

            Section("Video") {
                ScalePicker(title: "Video size", scale: $preferences.videoScale)
            }
        }
        .formStyle(.grouped)
    }
}

/// Picks an export magnification and shows the resulting pixel size.
private struct ScalePicker: View {
    let title: LocalizedStringKey
    @Binding var scale: Int

    var body: some View {
        Picker(title, selection: $scale) {
            ForEach([2, 3, 4, 6], id: \.self) { scale in
                // The P3 sensor has 256 × 192 pixels.
                Text(verbatim: "\(scale)×  (\(256 * scale) × \(192 * scale))").tag(scale)
            }
        }
    }
}

// MARK: - History

private struct HistoryPreferences: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            Picker("Keep history for", selection: $preferences.historyDurationMinutes) {
                ForEach([5, 15, 30, 60, 120], id: \.self) { minutes in
                    Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
                        .tag(minutes)
                }
            }
            Picker("Record a value every", selection: $preferences.historySampleInterval) {
                ForEach([0.1, 0.2, 0.5, 1.0, 5.0], id: \.self) { seconds in
                    Text(Duration.milliseconds(Int(seconds * 1000))
                        .formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))
                        .tag(seconds)
                }
            }
            Text("Longer histories and shorter intervals use more memory. The history is exported as CSV from the history panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private extension URL {
    /// "~/Pictures/Thermal Inspector" instead of "/Users/name/Pictures/Thermal Inspector".
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
