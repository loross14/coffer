import SwiftUI

struct MenubarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if appState.vaults.isEmpty {
                emptyState
            } else {
                vaultList
            }

            Divider()

            actionButtons
        }
        .frame(width: 300)
    }

    private var emptyState: some View {
        Text("No vaults configured")
            .foregroundStyle(.secondary)
            .padding()
    }

    private var vaultList: some View {
        ForEach(appState.vaults) { vault in
            VStack(spacing: 0) {
                HStack {
                    statusIcon(for: vault)
                    vaultInfo(for: vault)
                    Spacer()
                    actionButton(for: vault)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if vault.id != appState.vaults.last?.id {
                    Divider()
                }
            }
        }
    }

    private func statusIcon(for vault: Vault) -> some View {
        Image(systemName: vault.state == .locked ? "lock.fill" : "lock.open.fill")
            .foregroundStyle(vault.state == .locked ? .red : .green)
    }

    private func vaultInfo(for vault: Vault) -> some View {
        VStack(alignment: .leading) {
            Text(vault.name)
                .font(.headline)
            Text(vault.state.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionButton(for vault: Vault) -> some View {
        if let operation = appState.activeOperations[vault.id] {
            ProgressView(value: operation.progress)
                .frame(width: 40)
        } else if vault.state == .locked {
            Button("Unlock") {
                if vault.useTouchID {
                    Task {
                        await appState.unlockVaultWithBiometrics(vault.id)
                    }
                } else {
                    appState.promptForPassword(vaultID: vault.id, mode: .unlock)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            .controlSize(.small)
        } else if vault.state == .unlocked {
            Button("Lock") {
                appState.promptForPassword(vaultID: vault.id, mode: .lock)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .controlSize(.small)
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Add Vault") {
                appState.showAddVault = true
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
