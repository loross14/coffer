import CryptoKit
import Foundation
import PlanisphereCore

/// A logical storage boundary. A production adapter must derive this from authenticated access.
public struct ReplicaScope: Codable, Hashable, Sendable {
    public let tenantID: String
    public let vaultID: UUID

    public init(tenantID: String, vaultID: UUID) {
        self.tenantID = tenantID
        self.vaultID = vaultID
    }
}

/// An immutable publication attempt. Retrying an accepted operation requires identical content.
public struct ReplicaPublication: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let expectedParentID: UUID?
    public let checkpoint: Checkpoint

    public init(operationID: UUID = UUID(), expectedParentID: UUID?, checkpoint: Checkpoint) {
        self.operationID = operationID
        self.expectedParentID = expectedParentID
        self.checkpoint = checkpoint
    }
}

/// Acknowledges a historical publication, not a claim that this revision is still the head.
public struct ReplicaPublicationReceipt: Codable, Equatable, Sendable {
    public let scope: ReplicaScope
    public let operationID: UUID
    public let checkpointID: UUID
    public let parentID: UUID?
    public let manifestDigest: String

    public init(scope: ReplicaScope, operationID: UUID, checkpointID: UUID,
                parentID: UUID?, manifestDigest: String) {
        self.scope = scope
        self.operationID = operationID
        self.checkpointID = checkpointID
        self.parentID = parentID
        self.manifestDigest = manifestDigest
    }
}

public enum ReplicaError: Error, Equatable, Sendable {
    case invalidScope
    case invalidDigest(String)
    case digestMismatch(expected: String, actual: String)
    case invalidCheckpoint(String)
    case missingObject(String)
    case objectSizeMismatch(path: String, expected: Int64, actual: Int64)
    case headConflict(expected: UUID?, actual: UUID?)
    case operationConflict(UUID)
    case checkpointConflict(UUID)
}

public enum ReplicaDigest {
    public static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Object transfer can be retried separately from an atomic publication.
/// Implementations must verify content and compare-and-swap the scoped head before acknowledging.
public protocol ReplicaTransport: Sendable {
    func uploadObject(_ bytes: Data, digest: String, in scope: ReplicaScope) async throws
    func publish(_ publication: ReplicaPublication, in scope: ReplicaScope) async throws -> ReplicaPublicationReceipt
    func head(in scope: ReplicaScope) async throws -> Checkpoint?
    func checkpoint(id: UUID, in scope: ReplicaScope) async throws -> Checkpoint?
    func object(digest: String, in scope: ReplicaScope) async throws -> Data?
}

/// An executable protocol reference for tests and isolated experiments.
/// All state is lost on process exit. This is not a hosted, authenticated or durable service.
public actor InMemoryReplica: ReplicaTransport {
    private struct AcceptedOperation {
        let requestBytes: Data
        let receipt: ReplicaPublicationReceipt
    }

    private struct VaultState {
        var objects: [String: Data] = [:]
        var checkpoints: [UUID: Checkpoint] = [:]
        var manifestBytes: [UUID: Data] = [:]
        var operations: [UUID: AcceptedOperation] = [:]
        var headID: UUID?
    }

    private var vaults: [ReplicaScope: VaultState] = [:]

    public init() {}

    public func uploadObject(_ bytes: Data, digest: String, in scope: ReplicaScope) async throws {
        try validate(scope)
        try validateDigest(digest)
        let actual = ReplicaDigest.sha256(bytes)
        guard actual == digest else {
            throw ReplicaError.digestMismatch(expected: digest, actual: actual)
        }
        var state = vaults[scope] ?? VaultState()
        state.objects[digest] = bytes
        vaults[scope] = state
    }

    public func publish(_ publication: ReplicaPublication, in scope: ReplicaScope) async throws -> ReplicaPublicationReceipt {
        try validate(scope)
        let requestBytes = try VaultFormat.encode(publication)
        var state = vaults[scope] ?? VaultState()

        // Retry lookup precedes head checking: an acknowledgment may have been lost before later commits.
        if let prior = state.operations[publication.operationID] {
            guard prior.requestBytes == requestBytes else {
                throw ReplicaError.operationConflict(publication.operationID)
            }
            return prior.receipt
        }

        let checkpoint = publication.checkpoint
        try validate(checkpoint, scope: scope, expectedParentID: publication.expectedParentID,
                     objects: state.objects)
        let manifest = try VaultFormat.encode(checkpoint)
        if let prior = state.manifestBytes[checkpoint.id], prior != manifest {
            throw ReplicaError.checkpointConflict(checkpoint.id)
        }
        guard state.headID == publication.expectedParentID else {
            throw ReplicaError.headConflict(expected: publication.expectedParentID, actual: state.headID)
        }
        // No suspension points in this method: validation, compare-and-swap and receipt are one actor turn.
        let receipt = ReplicaPublicationReceipt(
            scope: scope, operationID: publication.operationID, checkpointID: checkpoint.id,
            parentID: checkpoint.parentID, manifestDigest: ReplicaDigest.sha256(manifest)
        )
        state.checkpoints[checkpoint.id] = checkpoint
        state.manifestBytes[checkpoint.id] = manifest
        state.headID = checkpoint.id
        state.operations[publication.operationID] = AcceptedOperation(requestBytes: requestBytes, receipt: receipt)
        vaults[scope] = state
        return receipt
    }

    public func head(in scope: ReplicaScope) async throws -> Checkpoint? {
        try validate(scope)
        guard let state = vaults[scope], let id = state.headID else { return nil }
        return state.checkpoints[id]
    }

    public func checkpoint(id: UUID, in scope: ReplicaScope) async throws -> Checkpoint? {
        try validate(scope)
        return vaults[scope]?.checkpoints[id]
    }

    public func object(digest: String, in scope: ReplicaScope) async throws -> Data? {
        try validate(scope)
        try validateDigest(digest)
        return vaults[scope]?.objects[digest]
    }

    private func validate(_ scope: ReplicaScope) throws {
        // Keep tenant IDs unambiguous and safe to carry into future URL/storage adapters.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !scope.tenantID.isEmpty, scope.tenantID.utf8.count <= 128,
              scope.tenantID != ".", scope.tenantID != "..",
              scope.tenantID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ReplicaError.invalidScope
        }
    }

    private func validateDigest(_ digest: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard digest.utf8.count == 64, digest.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ReplicaError.invalidDigest(digest)
        }
    }

    private func validate(_ checkpoint: Checkpoint, scope: ReplicaScope,
                          expectedParentID: UUID?, objects: [String: Data]) throws {
        guard checkpoint.formatVersion == 1, checkpoint.captureScope == nil else {
            throw ReplicaError.invalidCheckpoint("Unsupported format version.")
        }
        guard checkpoint.vaultID == scope.vaultID else {
            throw ReplicaError.invalidCheckpoint("Checkpoint belongs to a different vault.")
        }
        guard checkpoint.parentID == expectedParentID, checkpoint.id != checkpoint.parentID else {
            throw ReplicaError.invalidCheckpoint("Checkpoint parent does not match the publication precondition.")
        }
        guard checkpoint.createdAt.timeIntervalSince1970.isFinite else {
            throw ReplicaError.invalidCheckpoint("Checkpoint date must be finite.")
        }
        var paths: [String: FileEntry.Kind] = [:]
        var totalBytes: Int64 = 0
        for entry in checkpoint.entries {
            try validatePath(entry.path)
            // Canonically equivalent Unicode paths alias on ordinary Mac filesystems.
            let normalized = entry.path.precomposedStringWithCanonicalMapping
            guard paths[normalized] == nil else {
                throw ReplicaError.invalidCheckpoint("Duplicate path: \(entry.path)")
            }
            paths[normalized] = entry.kind
            guard entry.size >= 0 else {
                throw ReplicaError.invalidCheckpoint("Negative file size: \(entry.path)")
            }
            switch entry.kind {
            case .symbolicLink:
                throw ReplicaError.invalidCheckpoint("Symbolic links require checkpoint format 2, which this managed reference does not support.")
            case .directory:
                guard entry.digest == nil, entry.size == 0, !entry.executable else {
                    throw ReplicaError.invalidCheckpoint("Invalid directory entry: \(entry.path)")
                }
            case .file:
                guard let digest = entry.digest else {
                    throw ReplicaError.invalidCheckpoint("Missing file digest: \(entry.path)")
                }
                try validateDigest(digest)
                guard let bytes = objects[digest] else {
                    throw ReplicaError.missingObject(digest)
                }
                guard Int64(bytes.count) == entry.size else {
                    throw ReplicaError.objectSizeMismatch(path: entry.path, expected: entry.size,
                                                          actual: Int64(bytes.count))
                }
                let sum = totalBytes.addingReportingOverflow(entry.size)
                guard !sum.overflow else {
                    throw ReplicaError.invalidCheckpoint("Total file size exceeds the supported range.")
                }
                totalBytes = sum.partialValue
            }
        }
        for path in paths.keys {
            var parent = path.split(separator: "/").dropLast()
            while !parent.isEmpty {
                if paths[parent.joined(separator: "/")] == .file {
                    throw ReplicaError.invalidCheckpoint("A file is used as a directory: \(path)")
                }
                parent = parent.dropLast()
            }
        }
    }

    private func validatePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReplicaError.invalidCheckpoint("Unsafe relative path: \(path)")
        }
    }
}
