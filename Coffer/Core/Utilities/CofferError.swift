import Foundation

public enum CofferError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case vaultNotFound
    case manifestCorrupted
    case encryptedFileMissing(String)
    case cannotEnumerateDirectory
    case biometricsUnavailable
    case authenticationFailed
    case wrongPassword
    case masterKeyNotCached
    case insufficientDiskSpace
    case filesInUse([String])

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt data."
        case .decryptionFailed:
            return "Failed to decrypt data. The key may be incorrect."
        case .keychainWriteFailed(let status):
            return "Failed to write to Keychain (status: \(status))."
        case .keychainReadFailed(let status):
            return "Failed to read from Keychain (status: \(status))."
        case .keychainDeleteFailed(let status):
            return "Failed to delete from Keychain (status: \(status))."
        case .vaultNotFound:
            return "Vault not found."
        case .manifestCorrupted:
            return "Encryption manifest is corrupted. Manual recovery may be needed."
        case .encryptedFileMissing(let path):
            return "Encrypted file missing: \(path)"
        case .cannotEnumerateDirectory:
            return "Cannot read directory contents."
        case .biometricsUnavailable:
            return "Touch ID is not available on this device."
        case .authenticationFailed:
            return "Authentication failed or was cancelled."
        case .wrongPassword:
            return "Incorrect password."
        case .masterKeyNotCached:
            return "Master key not available. Please unlock with password."
        case .insufficientDiskSpace:
            return "Not enough disk space to complete encryption."
        case .filesInUse(let paths):
            return "Files are in use by another application: \(paths.joined(separator: ", "))"
        }
    }
}
