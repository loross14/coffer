import Foundation

public struct VaultRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String
    public let createdAt: Date
    public var archived: Bool
    public var restoredFrom: RestorationOrigin?

    public init(id: UUID = UUID(), name: String, path: String, createdAt: Date = Date(), archived: Bool = false, restoredFrom: RestorationOrigin? = nil) {
        self.id = id; self.name = name; self.path = path; self.createdAt = createdAt
        self.archived = archived; self.restoredFrom = restoredFrom
    }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

public struct RestorationOrigin: Codable, Equatable, Sendable {
    public let vaultID: UUID
    public let checkpointID: UUID
    public init(vaultID: UUID, checkpointID: UUID) { self.vaultID = vaultID; self.checkpointID = checkpointID }
}

public struct FileEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory }
    public let path: String
    public let kind: Kind
    public let digest: String?
    public let size: Int64
    public let executable: Bool
    public init(path: String, kind: Kind, digest: String? = nil, size: Int64 = 0, executable: Bool = false) {
        self.path = path; self.kind = kind; self.digest = digest; self.size = size; self.executable = executable
    }
}

public struct Checkpoint: Identifiable, Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let id: UUID
    public let vaultID: UUID
    public let parentID: UUID?
    public let createdAt: Date
    public let message: String
    public let entries: [FileEntry]
    public let restoredFrom: RestorationOrigin?
    public init(formatVersion: Int = 1, id: UUID = UUID(), vaultID: UUID, parentID: UUID?, createdAt: Date = Date(), message: String, entries: [FileEntry], restoredFrom: RestorationOrigin? = nil) {
        self.formatVersion = formatVersion; self.id = id; self.vaultID = vaultID; self.parentID = parentID
        self.createdAt = createdAt; self.message = message; self.entries = entries; self.restoredFrom = restoredFrom
    }
    public var fileCount: Int { entries.filter { $0.kind == .file }.count }
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
}

public struct FileChange: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case added, modified, deleted }
    public let path: String
    public let kind: Kind
    public let oldEntry: FileEntry?
    public let newEntry: FileEntry?
    public var id: String { path }
    public init(path: String, kind: Kind, oldEntry: FileEntry?, newEntry: FileEntry?) {
        self.path = path; self.kind = kind; self.oldEntry = oldEntry; self.newEntry = newEntry
    }
}

public enum VaultStoreError: LocalizedError, Sendable {
    case invalid(String)
    case unavailable(String)
    case changedDuringCapture
    case corrupt(String)
    case busy
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): return message
        case .changedDuringCapture: return "Files changed while the checkpoint was being captured. Pause editing and try again. No checkpoint was published."
        case .corrupt(let message): return "History could not be verified: \(message). Existing data has been preserved."
        case .busy: return "Another Planisphere operation is using this history store. Try again when it finishes."
        }
    }
}

/// Format v1 JSON uses sorted keys and UTC Unix seconds (including fractions) for dates.
/// Immutable object digests cover file bytes; transport implementations must preserve these fields.
public enum VaultFormat {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}
