import Foundation

/// An exact byte change approved through a local review. This is not signed policy authority.
public struct MarkdownMutation: Codable, Equatable, Sendable {
    public let path: String
    public let before: Data
    public let after: Data?
    public init(path: String, before: Data, after: Data?) {
        self.path = path; self.before = before; self.after = after
    }
}

public struct MarkdownMutationPlan: Codable, Equatable, Sendable {
    public let id: UUID
    public let vaultID: UUID
    public let vaultPath: String
    public let scope: CheckpointScope
    public let expectedFiles: [String: String]
    public let changes: [MarkdownMutation]
    public let reviewedPacket: Data
    public let digest: String
    internal let textReview: TextMutationReview?

    private struct Content: Codable {
        let id: UUID; let vaultID: UUID; let vaultPath: String
        let scope: CheckpointScope; let expectedFiles: [String: String]
        let changes: [MarkdownMutation]; let reviewedPacket: Data
        let textReview: TextMutationReview?
    }
    private var content: Content {
        Content(id: id, vaultID: vaultID, vaultPath: vaultPath, scope: scope,
                expectedFiles: expectedFiles, changes: changes, reviewedPacket: reviewedPacket, textReview: textReview)
    }

    public init(id: UUID = UUID(), vaultID: UUID, vaultPath: String, scope: CheckpointScope,
                expectedFiles: [String: String], changes: [MarkdownMutation], reviewedPacket: Data = Data()) throws {
        try self.init(id: id, vaultID: vaultID, vaultPath: vaultPath, scope: scope,
                      expectedFiles: expectedFiles, changes: changes, reviewedPacket: reviewedPacket, textReview: nil)
    }

    internal init(id: UUID, vaultID: UUID, vaultPath: String, scope: CheckpointScope,
                  expectedFiles: [String: String], changes: [MarkdownMutation], reviewedPacket: Data,
                  textReview: TextMutationReview?) throws {
        self.id = id; self.vaultID = vaultID; self.vaultPath = vaultPath; self.scope = scope
        self.expectedFiles = expectedFiles; self.changes = changes; self.reviewedPacket = reviewedPacket
        self.textReview = textReview
        let content = Content(id: id, vaultID: vaultID, vaultPath: vaultPath, scope: scope,
                              expectedFiles: expectedFiles, changes: changes, reviewedPacket: reviewedPacket, textReview: textReview)
        digest = VaultFS.hash(try VaultFormat.encode(content))
        try validate()
    }

    internal func validate() throws {
        try scope.validate()
        guard scope.mode == (textReview == nil ? .markdownOnly : .vaultContent), vaultPath.hasPrefix("/"),
              !changes.isEmpty, changes.count <= 2_000, expectedFiles.count <= 250_000,
              reviewedPacket.count <= 32 * 1024 * 1024 else {
            throw VaultStoreError.invalid("The reviewed Markdown mutation has an invalid scope or size.")
        }
        try textReview?.validate(scope: scope, expectedFiles: expectedFiles)
        var portable: Set<String> = []
        for (path, hash) in expectedFiles {
            try VaultFS.relative(path)
            guard (textReview != nil || path.hasSuffix(".md")), portable.insert(VaultFS.portablePathKey(path)).inserted,
                  hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                  !scope.excludes(path, isDirectory: false) else {
                throw VaultStoreError.invalid("The reviewed Markdown inventory is invalid.")
            }
            let parts = path.split(separator: "/")
            for index in 1..<parts.count {
                guard !scope.excludes(parts.prefix(index).joined(separator: "/"), isDirectory: true) else {
                    throw VaultStoreError.invalid("The reviewed inventory includes an excluded folder.")
                }
            }
        }
        var paths: Set<String> = [], byteCount = 0
        for change in changes {
            try VaultFS.relative(change.path)
            if let textReview {
                guard textReview.extensions.contains(URL(fileURLWithPath: change.path).pathExtension),
                      change.path.split(separator: "/").allSatisfy({ !$0.hasPrefix(".") }),
                      let entry = textReview.entries.first(where: { $0.path == change.path }),
                      entry.kind == .file, entry.size == Int64(change.before.count) else {
                    throw VaultStoreError.invalid("The changed path is not an included, reviewed text file.")
                }
            }
            guard paths.insert(change.path).inserted,
                  expectedFiles[change.path] == VaultFS.hash(change.before),
                  change.before.count <= 8 * 1024 * 1024,
                  String(data: change.before, encoding: .utf8) != nil, !change.before.contains(0),
                  change.after != change.before else {
                throw VaultStoreError.invalid("A proposed change does not match its reviewed original.")
            }
            if let after = change.after {
                guard after.count <= 8 * 1024 * 1024, String(data: after, encoding: .utf8) != nil, !after.contains(0) else {
                    throw VaultStoreError.invalid("A proposed replacement is not supported Markdown text.")
                }
            }
            byteCount += change.before.count + (change.after?.count ?? 0)
            guard byteCount <= 32 * 1024 * 1024 else { throw VaultStoreError.invalid("The proposed changes exceed 32 MiB.") }
        }
        guard VaultFS.hash(try VaultFormat.encode(content)) == digest else {
            throw VaultStoreError.corrupt("reviewed mutation digest mismatch")
        }
    }
}

public struct MarkdownMutationReceipt: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, interrupted, completed }
    public let id: UUID
    public let vaultID: UUID
    public let planDigest: String
    public let beforeCheckpointID: UUID
    public internal(set) var afterCheckpointID: UUID?
    public let startedAt: Date
    public internal(set) var finishedAt: Date?
    public internal(set) var status: Status
    public internal(set) var recoveryAcknowledgedAt: Date?
    public let changedPaths: [String]
    public internal(set) var appliedPaths: [String]
    /// Completed operations retain displaced originals here. During interruption,
    /// a path may still contain a staged replacement; inspect alongside the journal.
    public let recoveryPaths: [String]
    public internal(set) var error: String?
}
