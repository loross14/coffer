import SwiftUI

@MainActor
@Observable
final class AppState {
    var vaults: [Vault] = []
    var activeOperations: [UUID: VaultOperation] = [:]
    var selectedVaultID: UUID?
    var showAddVault: Bool = false
    var showOnboarding: Bool = false
    var errorMessage: String?

    // Password entry state
    var showPasswordEntry: Bool = false
    var passwordEntryVaultID: UUID?
    var passwordEntryMode: PasswordEntryMode = .unlock

    enum PasswordEntryMode {
        case lock
        case unlock
    }

    private let vaultManager = VaultManager.shared

    struct VaultOperation: Sendable {
        var progress: Double
        var currentFile: String
        var type: OperationType

        enum OperationType: Sendable {
            case encrypting
            case decrypting
        }
    }

    init() {
        loadVaults()
        checkOnboarding()
    }

    var isBiometricsAvailable: Bool { vaultManager.isBiometricsAvailable }
    var settings: GlobalSettings { vaultManager.settings }

    private func loadVaults() {
        vaults = vaultManager.vaults
    }

    private func checkOnboarding() {
        // Show onboarding on first launch (no vaults yet)
        showOnboarding = vaults.isEmpty
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        showOnboarding = false
    }

    // MARK: - Add Vault

    func addVault(
        name: String,
        folderPath: String,
        password: String,
        useTouchID: Bool,
        autoLockMinutes: Int
    ) {
        do {
            _ = try vaultManager.addVault(
                name: name,
                folderPath: folderPath,
                password: password,
                useTouchID: useTouchID,
                autoLockMinutes: autoLockMinutes
            )
            loadVaults()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Lock

    func lockVault(_ vaultID: UUID, password: String) {
        activeOperations[vaultID] = VaultOperation(
            progress: 0, currentFile: "", type: .encrypting
        )

        do {
            try vaultManager.lockVault(vaultID, password: password) { [weak self] current, total in
                guard let self else { return }
                self.activeOperations[vaultID]?.progress = Double(current) / Double(total)
            }
            loadVaults()
        } catch {
            errorMessage = error.localizedDescription
            loadVaults()
        }

        activeOperations.removeValue(forKey: vaultID)
    }

    // MARK: - Unlock (Touch ID)

    func unlockVaultWithBiometrics(_ vaultID: UUID) async {
        activeOperations[vaultID] = VaultOperation(
            progress: 0, currentFile: "", type: .decrypting
        )

        do {
            try await vaultManager.unlockVaultWithBiometrics(vaultID) { [weak self] current, total in
                guard let self else { return }
                self.activeOperations[vaultID]?.progress = Double(current) / Double(total)
            }
            loadVaults()
        } catch {
            // Touch ID failed — prompt for password instead
            activeOperations.removeValue(forKey: vaultID)
            loadVaults()
            promptForPassword(vaultID: vaultID, mode: .unlock)
            return
        }

        activeOperations.removeValue(forKey: vaultID)
    }

    // MARK: - Unlock (Password)

    func unlockVaultWithPassword(_ vaultID: UUID, password: String) {
        activeOperations[vaultID] = VaultOperation(
            progress: 0, currentFile: "", type: .decrypting
        )

        do {
            try vaultManager.unlockVaultWithPassword(vaultID, password: password) { [weak self] current, total in
                guard let self else { return }
                self.activeOperations[vaultID]?.progress = Double(current) / Double(total)
            }
            loadVaults()
        } catch {
            errorMessage = error.localizedDescription
            loadVaults()
        }

        activeOperations.removeValue(forKey: vaultID)
    }

    // MARK: - Remove Vault

    func removeVault(_ vaultID: UUID) async {
        do {
            try await vaultManager.removeVault(vaultID)
            loadVaults()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Password Prompt

    func promptForPassword(vaultID: UUID, mode: PasswordEntryMode) {
        passwordEntryVaultID = vaultID
        passwordEntryMode = mode
        showPasswordEntry = true
    }

    func dismissPasswordEntry() {
        showPasswordEntry = false
        passwordEntryVaultID = nil
    }

    // MARK: - Settings

    func updateSettings(_ settings: GlobalSettings) {
        do {
            try vaultManager.updateSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
