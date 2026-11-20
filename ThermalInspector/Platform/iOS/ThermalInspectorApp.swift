import ExternalAccessory
import SwiftUI

@main
struct ThermalInspectorApp: App {
    @State private var model = AppModel()

    init() {
        // Keeps the list of connected accessories (the camera) up to date.
        EAAccessoryManager.shared().registerForLocalNotifications()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.startCamera() }
        }
    }
}
