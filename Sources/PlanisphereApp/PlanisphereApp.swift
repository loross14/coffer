import SwiftUI
import AppKit

@main
struct PlanisphereApp: App {
    @State private var model = VaultAppModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup("Planisphere") {
            VaultWorkspaceView(model: model)
                .frame(minWidth: 1060, minHeight: 660)
                .task { await model.start() }
                .onOpenURL { url in
                    guard url.scheme == "ooo.planisphere.mac", url.host == nil, url.query == nil, url.fragment == nil, model.canNavigateWorkspace else { return }
                    if url.path == "/prompts" { model.activitySurface = .prompts }
                    if url.path == "/hooks" { model.activitySurface = .hooks }
                    if url.path == "/memory" { model.activitySurface = .memory }
                }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Existing Vault…") { model.chooseExistingVault() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(!model.canNavigateWorkspace || model.commandPalettePresented)
                Button("Create New Vault…") { model.chooseNewVault() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(!model.canNavigateWorkspace || model.commandPalettePresented)
            }
            CommandMenu("Workspace") {
                if ConsoleConnectionModel.isAvailable {
                    Button("Console Connection…") { model.console.presented = true }
                        .disabled(!model.canNavigateWorkspace)
                } else {
                    Link("Open Console in Browser", destination: ConsoleConnectionModel.consoleURL)
                }
                Button("Go Anywhere…") { model.toggleCommandPalette() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!model.canNavigateWorkspace)
                Button("Close Go Anywhere") { model.commandPalettePresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!model.commandPalettePresented)
                Divider()
                ForEach(Array(VaultSurface.allCases.enumerated()), id: \.element) { index, surface in
                    Button("Open \(surface.rawValue)") { model.selectedSurface = surface }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .disabled(!model.canNavigateWorkspace || model.selectedVault == nil || model.commandPalettePresented)
                }
                Divider()
                ForEach(Array(ActivitySurface.allCases.enumerated()), id: \.element) { index, surface in
                    Button("Open \(surface.rawValue)") { model.activitySurface = surface }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 4))), modifiers: .command)
                        .disabled(!model.canNavigateWorkspace || model.commandPalettePresented)
                }
                Divider()
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
                    .keyboardShortcut("\\", modifiers: .command)
                    .disabled(!model.canNavigateWorkspace || model.commandPalettePresented)
                Button("Create Checkpoint…") { model.createCheckpoint() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canNavigateWorkspace || model.selectedVault == nil || model.historyReadError != nil || model.commandPalettePresented)
            }
        }
    }
}
