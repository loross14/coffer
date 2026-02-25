import SwiftUI

struct VaultListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationStack {
            if appState.vaults.isEmpty {
                ContentUnavailableView {
                    Label("No Vaults", systemImage: "lock.shield")
                } description: {
                    Text("Add a folder to protect it with Touch ID and AES-256 encryption.")
                } actions: {
                    Button("Add Vault") {
                        appState.showAddVault = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240, maximum: 320))],
                        spacing: 16
                    ) {
                        ForEach(appState.vaults) { vault in
                            VaultCardView(vault: vault)
                        }
                    }
                    .padding()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showAddVault = true
                } label: {
                    Label("Add Vault", systemImage: "plus")
                }
            }
        }
        .navigationTitle(Constants.appName)
        .sheet(isPresented: $appState.showOnboarding) {
            OnboardingView()
                .environment(appState)
                .interactiveDismissDisabled(appState.vaults.isEmpty)
        }
        .sheet(isPresented: $appState.showAddVault) {
            AddVaultView()
                .environment(appState)
        }
        .sheet(isPresented: $appState.showPasswordEntry) {
            if let vaultID = appState.passwordEntryVaultID,
               let vault = appState.vaults.first(where: { $0.id == vaultID }) {
                PasswordEntryView(
                    vaultName: vault.name,
                    isLocking: appState.passwordEntryMode == .lock,
                    onSubmit: { password in
                        appState.dismissPasswordEntry()
                        if appState.passwordEntryMode == .lock {
                            appState.lockVault(vaultID, password: password)
                        } else {
                            appState.unlockVaultWithPassword(vaultID, password: password)
                        }
                    },
                    onCancel: {
                        appState.dismissPasswordEntry()
                    }
                )
            }
        }
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            if let msg = appState.errorMessage {
                Text(msg)
            }
        }
    }
}
