#if DEBUG
import AppKit

/// Development helper: renders the main window into a PNG, so the UI can be
/// checked without screen-recording permission.
///
///     "Thermal Inspector" -cameraSource simulation -debugScreenshot /tmp/ui.png
///         [-debugDelay 100] [-debugDetail YES] [-debugSettings YES] [-debugSkipSnapshot YES]
///
/// Waits a few seconds, places some demo measurements, then writes the file
/// (and a regular snapshot into the output folder) and quits.
@MainActor
enum DebugScreenshot {
    static func runIfRequested(model: AppModel) {
        guard let path = UserDefaults.standard.string(forKey: "debugScreenshot") else { return }

        Task {
            try? await Task.sleep(for: .seconds(4))
            model.addSpot(at: PixelPoint(x: 178, y: 46))
            model.addBox(PixelRect(from: PixelPoint(x: 66, y: 66), to: PixelPoint(x: 118, y: 118)))
            // -debugDelay <seconds>: wait longer, e.g. to observe an automatic calibration.
            let delay = max(UserDefaults.standard.double(forKey: "debugDelay"), 8)
            try? await Task.sleep(for: .seconds(delay))
            // -debugSkipSnapshot YES: do not write a snapshot into the output folder.
            if !UserDefaults.standard.bool(forKey: "debugSkipSnapshot") { model.saveSnapshot() }
            try? await Task.sleep(for: .seconds(1))

            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                // Bring the window to the front so it is drawn as active.
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                capture(window, to: path)

                // With -debugDetail YES, also capture the detail image ("<path>-detail.png").
                if UserDefaults.standard.bool(forKey: "debugDetail") {
                    let originalMode = model.imageMode
                    model.imageMode = .detail
                    try? await Task.sleep(for: .seconds(1))
                    capture(window, to: path.replacingOccurrences(of: ".png", with: "-detail.png"))
                    model.imageMode = originalMode
                }
            }

            // With -debugSettings YES, also capture the Settings window ("<path>-settings.png").
            if UserDefaults.standard.bool(forKey: "debugSettings") {
                let mainWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
                // Same as choosing "Settings…" (⌘,) in the app menu.
                if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                   let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    appMenu.performActionForItem(at: index)
                }
                try? await Task.sleep(for: .seconds(1))
                if let settings = NSApp.windows.first(where: { $0.isVisible && !mainWindows.contains(ObjectIdentifier($0)) }) {
                    capture(settings, to: path.replacingOccurrences(of: ".png", with: "-settings.png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to path: String) {
        // The content view's superview also contains the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
