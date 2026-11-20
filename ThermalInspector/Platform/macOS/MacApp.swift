import SwiftUI

@main
struct ThermalInspectorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Thermal Inspector", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    model.startCamera()
                    #if DEBUG
                    DebugScreenshot.runIfRequested(model: model)
                    #endif
                }
        }
        .commands {
            AppCommands(model: model)
        }

        Settings {
            PreferencesView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the stream cleanly – a camera left streaming can hang until replugged.
        NotificationCenter.default.post(name: .appWillQuit, object: nil)
    }
}

/// Menu bar entries with keyboard shortcuts.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Capture") {
            Button("Save Snapshot") { model.saveSnapshot() }
                .keyboardShortcut("s", modifiers: .command)
            Button(model.isRecording ? LocalizedStringKey("Stop Video Recording") : "Start Video Recording") {
                model.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button(model.isFrozen ? LocalizedStringKey("Resume Live Image") : "Freeze Image") { model.isFrozen.toggle() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Open Output Folder") { model.openOutputFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Analysis") {
            Button("Capture Reference") { model.captureReference() }
                .keyboardShortcut("d", modifiers: .command)
            Toggle("Show Difference Image", isOn: Binding(get: { model.showDifference }, set: { model.showDifference = $0 }))
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.referenceFrame == nil)
            Divider()
            Button("Lock Range") { model.lockCurrentRange() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Remove All Measurements") { model.clearMeasurements() }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("Shutter / Recalibrate") { model.triggerShutter() }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}
