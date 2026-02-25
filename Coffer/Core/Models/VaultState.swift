import Foundation

public enum VaultState: String, Codable, Sendable {
    case locked
    case unlocked
    case encrypting
    case decrypting
    case error
}
