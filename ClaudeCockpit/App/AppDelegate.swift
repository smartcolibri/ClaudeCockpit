import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBarOnly = UserDefaults.standard.bool(forKey: SettingsKey.menuBarOnly)
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        if menuBarOnly {
            // Menu-bar-only mode: the main window must not pop at launch.
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.title == "Claude Cockpit" }.forEach { $0.close() }
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    /// `openMainWindow()` raises the app to `.regular` so the window has a reachable
    /// Dock icon; nothing else drops it back. Filtered by title so the Settings
    /// window (a different title) never triggers this.
    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.title == "Claude Cockpit" else { return }
        guard UserDefaults.standard.bool(forKey: SettingsKey.menuBarOnly) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .cockpitOpenMainWindow, object: nil) }
        return true
    }
}

extension Notification.Name {
    static let cockpitOpenMainWindow = Notification.Name("fr.vincentlauriat.claudecockpit.openMainWindow")
}
