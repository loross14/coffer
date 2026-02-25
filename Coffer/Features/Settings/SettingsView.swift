import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var autoLockOnSleep = true
    @State private var autoLockOnScreenLock = true
    @State private var defaultAutoLockMinutes = 5
    @State private var showDockIcon = true

    var body: some View {
        TabView {
            Form {
                Section("Auto-Lock") {
                    Toggle("Lock vaults on sleep", isOn: $autoLockOnSleep)
                    Toggle("Lock vaults on screen lock", isOn: $autoLockOnScreenLock)
                    Stepper("Default auto-lock: \(defaultAutoLockMinutes) min", value: $defaultAutoLockMinutes, in: 0...60)
                }

                Section("Appearance") {
                    Toggle("Show dock icon", isOn: $showDockIcon)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gear")
            }
            .onChange(of: autoLockOnSleep) { saveSettings() }
            .onChange(of: autoLockOnScreenLock) { saveSettings() }
            .onChange(of: defaultAutoLockMinutes) { saveSettings() }
            .onChange(of: showDockIcon) { saveSettings() }

            Form {
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Author", value: "Logan Ross")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
        .frame(width: 400, height: 300)
        .onAppear { loadSettings() }
    }

    private func loadSettings() {
        let s = appState.settings
        autoLockOnSleep = s.autoLockOnSleep
        autoLockOnScreenLock = s.autoLockOnScreenLock
        defaultAutoLockMinutes = s.defaultAutoLockMinutes
        showDockIcon = s.showDockIcon
    }

    private func saveSettings() {
        let settings = GlobalSettings(
            autoLockOnSleep: autoLockOnSleep,
            autoLockOnScreenLock: autoLockOnScreenLock,
            defaultAutoLockMinutes: defaultAutoLockMinutes,
            showDockIcon: showDockIcon
        )
        appState.updateSettings(settings)
    }
}
