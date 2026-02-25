import Foundation

public struct EncryptionManifest: Codable, Sendable {
    public let vaultID: UUID
    public let version: Int
    public let startedAt: Date
    public var completedAt: Date?
    public var files: [FileEntry]
    public var status: ManifestStatus

    public enum ManifestStatus: String, Codable, Sendable {
        case inProgress
        case completed
        case interrupted
    }

    public struct FileEntry: Codable, Sendable {
        public let relativePath: String
        public let originalSize: Int64
        public let encryptedSize: Int64
        public var isEncrypted: Bool
        public let nonce: Data
        public let tag: Data
        public let posixPermissions: UInt16

        public init(
            relativePath: String,
            originalSize: Int64,
            encryptedSize: Int64,
            isEncrypted: Bool,
            nonce: Data,
            tag: Data,
            posixPermissions: UInt16
        ) {
            self.relativePath = relativePath
            self.originalSize = originalSize
            self.encryptedSize = encryptedSize
            self.isEncrypted = isEncrypted
            self.nonce = nonce
            self.tag = tag
            self.posixPermissions = posixPermissions
        }
    }

    public init(vaultID: UUID, version: Int = 1, files: [FileEntry] = []) {
        self.vaultID = vaultID
        self.version = version
        self.startedAt = Date()
        self.completedAt = nil
        self.files = files
        self.status = .inProgress
    }
}
