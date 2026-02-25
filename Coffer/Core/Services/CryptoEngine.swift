import Foundation
import CryptoKit
import os

/// Core encryption primitives for Coffer.
/// Uses AES-256-GCM via CryptoKit. HKDF-SHA256 for key derivation.
/// Two-layer key system: master key encrypts files, password-derived key wraps master key.
public enum CryptoEngine {

    // MARK: - Key Derivation

    /// Derives a 256-bit symmetric key from a user password using HKDF-SHA256.
    public static func deriveKey(from password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: salt,
            info: Data(Constants.Crypto.hkdfInfo.utf8),
            outputByteCount: Constants.Crypto.keyLength
        )
    }

    /// Generates a random salt for key derivation.
    public static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: Constants.Crypto.saltLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Fallback (should never happen on macOS)
            return Data((0..<Constants.Crypto.saltLength).map { _ in UInt8.random(in: 0...255) })
        }
        return Data(bytes)
    }

    // MARK: - Master Key

    /// Generates a random 256-bit master key.
    public static func generateMasterKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Wraps (encrypts) the master key with a password-derived wrapping key.
    public static func wrapMasterKey(_ masterKey: SymmetricKey, with wrappingKey: SymmetricKey) throws -> Data {
        let masterKeyData = masterKey.withUnsafeBytes { Data($0) }
        return try encrypt(data: masterKeyData, using: wrappingKey).sealed
    }

    /// Unwraps the master key using the password-derived wrapping key.
    /// Throws if the wrapping key (password) is wrong — GCM tag verification fails.
    public static func unwrapMasterKey(_ wrapped: Data, with wrappingKey: SymmetricKey) throws -> SymmetricKey {
        let keyData = try decrypt(combined: wrapped, using: wrappingKey)
        return SymmetricKey(data: keyData)
    }

    /// Extracts the raw bytes of a SymmetricKey as Data.
    public static func keyToData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypts data using AES-256-GCM.
    /// Returns the combined (nonce + ciphertext + tag) blob and the nonce separately.
    public static func encrypt(data: Data, using key: SymmetricKey) throws -> (sealed: Data, nonce: Data, tag: Data) {
        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
            guard let combined = sealedBox.combined else {
                throw CofferError.encryptionFailed
            }
            return (combined, Data(nonce), Data(sealedBox.tag))
        } catch let error as CofferError {
            throw error
        } catch {
            Log.crypto.error("Encryption failed: \(error.localizedDescription)")
            throw CofferError.encryptionFailed
        }
    }

    /// Decrypts AES-256-GCM combined data (nonce + ciphertext + tag).
    public static func decrypt(combined: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            Log.crypto.error("Decryption failed: \(error.localizedDescription)")
            throw CofferError.decryptionFailed
        }
    }
}
