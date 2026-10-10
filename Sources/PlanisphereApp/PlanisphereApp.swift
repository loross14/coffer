import SwiftUI
import AppKit

@main
struct PlanisphereApp: App {
    @State private var model = VaultAppModel()

    var body: some Scene {
        WindowGroup("Planisphere") {
            VaultWorkspaceView(model: model)
                .frame(minWidth: 1060, minHeight: 660)
                .task { await model.start() }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Existing Vault…") { model.chooseExistingVault() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(model.isBusy)
                Button("Create New Vault…") { model.chooseNewVault() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(model.isBusy)
            }
        }
    }
}
