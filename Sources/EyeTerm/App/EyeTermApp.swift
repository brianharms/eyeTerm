import SwiftUI

@main
struct EyeTermApp: App {
    @State private var appState: AppState
    @State private var coordinator: AppCoordinator

    init() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let state = AppState()
        state.loadPersistedSettings()
        _appState = State(initialValue: state)
        _coordinator = State(initialValue: AppCoordinator(appState: state))
    }

    var body: some Scene {
        MenuBarExtra("eyeTerm", systemImage: "eye") {
            MenuBarView()
                .environment(appState)
                .environment(coordinator)
        }

        Settings {
            SettingsView()
                .environment(appState)
                .environment(coordinator)
        }
    }
}
