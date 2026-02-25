import Foundation

public struct Vault: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var folderPath: String
    public var state: VaultState
    public var createdAt: Date
    public var lastUnlockedAt: Date?
    public var autoLockMinutes: Int
    public var useTouchID: Bool
    public var fileCount: Int
    public var totalSize: Int64

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: String,
        state: VaultState = .unlocked,
        createdAt: Date = Date(),
        lastUnlockedAt: Date? = nil,
        autoLockMinutes: Int = 5,
        useTouchID: Bool = true,
        fileCount: Int = 0,
        totalSize: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.state = state
        self.createdAt = createdAt
        self.lastUnlockedAt = lastUnlockedAt
        self.autoLockMinutes = autoLockMinutes
        self.useTouchID = useTouchID
        self.fileCount = fileCount
        self.totalSize = totalSize
    }
}
