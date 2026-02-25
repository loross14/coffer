import Foundation
import Security
import LocalAuthentication
import os

/// Manages Keychain storage for vault master keys and salts.
/// Supports biometric-protected access (Touch ID) via access control flags.
public enum KeychainService {

    // MARK: - Master Key (Biometric-Protected)

    /// Stores a vault's master key in the Keychain with biometric access control.
    /// The key can only be retrieved after successful Touch ID authentication.
    public static func storeMasterKey(_ keyData: Data, forVaultID vaultID: UUID, context: LAContext? = nil) throws {
        let account = "\(Constants.Keychain.masterKeyPrefix).\(vaultID.uuidString)"

        // Biometric-only access control — key is invalidated if biometrics change
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw CofferError.keychainWriteFailed(errSecParam)
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessControl as String: accessControl,
        ]

        // If we have an authenticated LAContext, attach it so the OS doesn't re-prompt
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.keychain.error("Failed to store master key for vault \(vaultID): \(status)")
            throw CofferError.keychainWriteFailed(status)
        }

        Log.keychain.info("Stored master key for vault \(vaultID)")
    }

    /// Retrieves a vault's master key from the Keychain.
    /// Triggers Touch ID prompt if the key has biometric access control.
    public static func retrieveMasterKey(forVaultID vaultID: UUID, context: LAContext? = nil) throws -> Data {
        let account = "\(Constants.Keychain.masterKeyPrefix).\(vaultID.uuidString)"

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]

        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            Log.keychain.error("Failed to retrieve master key for vault \(vaultID): \(status)")
            throw CofferError.keychainReadFailed(status)
        }

        return data
    }

    /// Deletes a vault's master key from the Keychain.
    public static func deleteMasterKey(forVaultID vaultID: UUID) throws {
        let account = "\(Constants.Keychain.masterKeyPrefix).\(vaultID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.keychain.error("Failed to delete master key for vault \(vaultID): \(status)")
            throw CofferError.keychainDeleteFailed(status)
        }

        Log.keychain.info("Deleted master key for vault \(vaultID)")
    }

    // MARK: - Salt (Non-Biometric)

    /// Stores the password salt for a vault. No biometric protection needed —
    /// the salt is not secret, but storing it in Keychain keeps it off disk.
    public static func storeSalt(_ salt: Data, forVaultID vaultID: UUID) throws {
        let account = "\(Constants.Keychain.saltPrefix).\(vaultID.uuidString)"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: salt,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.keychain.error("Failed to store salt for vault \(vaultID): \(status)")
            throw CofferError.keychainWriteFailed(status)
        }
    }

    /// Retrieves the password salt for a vault.
    public static func retrieveSalt(forVaultID vaultID: UUID) throws -> Data {
        let account = "\(Constants.Keychain.saltPrefix).\(vaultID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            Log.keychain.error("Failed to retrieve salt for vault \(vaultID): \(status)")
            throw CofferError.keychainReadFailed(status)
        }

        return data
    }

    /// Deletes the salt for a vault.
    public static func deleteSalt(forVaultID vaultID: UUID) throws {
        let account = "\(Constants.Keychain.saltPrefix).\(vaultID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.keychain.error("Failed to delete salt for vault \(vaultID): \(status)")
            throw CofferError.keychainDeleteFailed(status)
        }
    }

    // MARK: - Wrapped Master Key (Password-Protected)

    /// Stores the password-wrapped (encrypted) master key for a vault.
    /// This is the fallback when Touch ID is unavailable — user enters password,
    /// we derive a key, and unwrap the master key from this blob.
    public static func storeWrappedMasterKey(_ wrappedData: Data, forVaultID vaultID: UUID) throws {
        let account = "\(Constants.Keychain.masterKeyPrefix).\(Constants.Keychain.wrappedSuffix).\(vaultID.uuidString)"

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: wrappedData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.keychain.error("Failed to store wrapped master key for vault \(vaultID): \(status)")
            throw CofferError.keychainWriteFailed(status)
        }
    }

    /// Retrieves the password-wrapped master key for a vault.
    public static func retrieveWrappedMasterKey(forVaultID vaultID: UUID) throws -> Data {
        let account = "\(Constants.Keychain.masterKeyPrefix).\(Constants.Keychain.wrappedSuffix).\(vaultID.uuidString)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            Log.keychain.error("Failed to retrieve wrapped master key for vault \(vaultID): \(status)")
            throw CofferError.keychainReadFailed(status)
        }

        return data
    }

    // MARK: - Cleanup

    /// Deletes all Keychain entries for a vault (master key, salt, wrapped key).
    public static func deleteAllEntries(forVaultID vaultID: UUID) {
        try? deleteMasterKey(forVaultID: vaultID)
        try? deleteSalt(forVaultID: vaultID)

        // Delete wrapped master key
        let wrappedAccount = "\(Constants.Keychain.masterKeyPrefix).\(Constants.Keychain.wrappedSuffix).\(vaultID.uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.Keychain.service,
            kSecAttrAccount as String: wrappedAccount,
        ]
        SecItemDelete(query as CFDictionary)

        Log.keychain.info("Deleted all Keychain entries for vault \(vaultID)")
    }
}
