import Foundation
import LocalAuthentication
import CryptoKit
import os

/// Handles authentication for vault unlock using Touch ID + password.
/// Returns the decrypted master key on success.
@MainActor @Observable
public final class AuthService {

    public private(set) var isBiometricsAvailable = false

    public init() {
        checkBiometrics()
    }

    /// Checks whether Touch ID is available on this machine.
    public func checkBiometrics() {
        let context = LAContext()
        var error: NSError?
        isBiometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if let error {
            Log.auth.info("Biometrics not available: \(error.localizedDescription)")
        }
    }

    // MARK: - Touch ID Authentication

    /// Unlocks a vault using Touch ID and retrieves the master key from Keychain.
    public func unlockWithBiometrics(vaultID: UUID, vaultName: String) async throws -> SymmetricKey {
        let context = LAContext()
        context.localizedReason = "Unlock \(vaultName)"
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            Log.auth.error("Biometrics unavailable: \(error?.localizedDescription ?? "unknown")")
            throw CofferError.biometricsUnavailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock \"\(vaultName)\""
            )
            guard success else {
                throw CofferError.authenticationFailed
            }
        } catch let error as LAError {
            Log.auth.error("Touch ID failed: \(error.localizedDescription)")
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw CofferError.authenticationFailed
            case .biometryNotAvailable, .biometryNotEnrolled:
                throw CofferError.biometricsUnavailable
            default:
                throw CofferError.authenticationFailed
            }
        }

        // Touch ID succeeded — retrieve master key from Keychain using the authenticated context
        let keyData = try KeychainService.retrieveMasterKey(forVaultID: vaultID, context: context)
        Log.auth.info("Biometric unlock succeeded for vault \(vaultID)")
        return SymmetricKey(data: keyData)
    }

    // MARK: - Password Authentication

    /// Authenticates with a password by deriving a key and unwrapping the master key.
    public func unlockWithPassword(_ password: String, vaultID: UUID) throws -> SymmetricKey {
        // Retrieve the salt and wrapped master key from Keychain
        let salt = try KeychainService.retrieveSalt(forVaultID: vaultID)
        let wrappedMasterKey = try KeychainService.retrieveWrappedMasterKey(forVaultID: vaultID)

        // Derive the wrapping key from the password
        let derivedKey = CryptoEngine.deriveKey(from: password, salt: salt)

        // Attempt to unwrap — if password is wrong, GCM tag verification fails
        do {
            let masterKey = try CryptoEngine.unwrapMasterKey(wrappedMasterKey, with: derivedKey)
            Log.auth.info("Password unlock succeeded for vault \(vaultID)")
            return masterKey
        } catch {
            Log.auth.error("Password unlock failed for vault \(vaultID) — wrong password")
            throw CofferError.wrongPassword
        }
    }

    // MARK: - Vault Setup

    /// Sets up authentication for a new vault.
    /// Generates master key, wraps it with password-derived key, stores in Keychain.
    /// Optionally stores biometric-protected copy for Touch ID unlock.
    public func setupVault(
        vaultID: UUID,
        password: String,
        enableTouchID: Bool
    ) throws -> SymmetricKey {
        let masterKey = CryptoEngine.generateMasterKey()
        let masterKeyData = CryptoEngine.keyToData(masterKey)
        let salt = CryptoEngine.generateSalt()
        let derivedKey = CryptoEngine.deriveKey(from: password, salt: salt)
        let wrappedMasterKey = try CryptoEngine.wrapMasterKey(masterKey, with: derivedKey)

        // Store salt and wrapped master key (always — password fallback)
        try KeychainService.storeSalt(salt, forVaultID: vaultID)
        try KeychainService.storeWrappedMasterKey(wrappedMasterKey, forVaultID: vaultID)

        // Store biometric-protected master key if Touch ID is enabled
        if enableTouchID && self.isBiometricsAvailable {
            try KeychainService.storeMasterKey(masterKeyData, forVaultID: vaultID)
        }

        Log.auth.info("Vault \(vaultID) setup complete (Touch ID: \(enableTouchID && self.isBiometricsAvailable))")
        return masterKey
    }

    // MARK: - Change Password

    /// Changes the password for an existing vault.
    public func changePassword(
        vaultID: UUID,
        currentPassword: String,
        newPassword: String
    ) throws {
        // Verify current password and get master key
        let masterKey = try unlockWithPassword(currentPassword, vaultID: vaultID)

        // Generate new salt and derive new wrapping key
        let newSalt = CryptoEngine.generateSalt()
        let newDerivedKey = CryptoEngine.deriveKey(from: newPassword, salt: newSalt)
        let newWrapped = try CryptoEngine.wrapMasterKey(masterKey, with: newDerivedKey)

        // Update Keychain
        try KeychainService.storeSalt(newSalt, forVaultID: vaultID)
        try KeychainService.storeWrappedMasterKey(newWrapped, forVaultID: vaultID)

        Log.auth.info("Password changed for vault \(vaultID)")
    }
}
