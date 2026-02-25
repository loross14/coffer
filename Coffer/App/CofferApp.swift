import SwiftUI
import os

@main
struct CofferApp: App {
    @State private var appState = AppState()
    @State private var autoLockService = AutoLockService()

    var body: some Scene {
        WindowGroup {
            VaultListView()
                .environment(appState)
                .frame(
                    minWidth: Constants.UI.windowMinWidth,
                    minHeight: Constants.UI.windowMinHeight
                )
                .onAppear {
                    autoLockService.startMonitoring {
                        Log.autoLock.info("Auto-lock triggered but password-based locking requires user input")
                    }
                }
        }
        .defaultSize(width: 600, height: 500)

        MenuBarExtra(Constants.appName, systemImage: Constants.UI.menubarIcon) {
            MenubarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
