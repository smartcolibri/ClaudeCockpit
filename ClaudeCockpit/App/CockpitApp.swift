import SwiftUI
import CockpitShared

@main
struct CockpitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = CockpitStore()

    var body: some Scene {
        // The main window comes first so SwiftUI opens it at launch (unless the
        // user chose the menu-bar-only mode, handled in AppDelegate).
        Window(MainWindowView.windowTitle, id: MainWindowView.windowID) {
            MainWindowView()
                .environment(store)
                .environment(\.locale, AppFormat.locale)
        }
        .defaultSize(width: 1160, height: 760)

        MenuBarExtra {
            MenuBarPanelView()
                .environment(store)
                .environment(\.locale, AppFormat.locale)
        } label: {
            // The label lives as long as the status item, so it is the one place
            // guaranteed to exist at launch: it bridges `openWindow` to the store
            // and starts the refresh loops.
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(\.locale, AppFormat.locale)
        }
    }
}

/// Menu-bar label: gauge glyph + today's cost. Also the launch-time bridge.
private struct MenuBarLabel: View {
    let store: CockpitStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(store.menuBarTitle).monospacedDigit()
        }
        .onAppear {
            store.openWindowHandler = { openWindow(id: MainWindowView.windowID) }
            store.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cockpitOpenMainWindow)) { _ in
            openWindow(id: MainWindowView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
