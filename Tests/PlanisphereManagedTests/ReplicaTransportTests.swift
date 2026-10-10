import Foundation
import PlanisphereCore
import PlanisphereManaged
import Testing

struct ReplicaTransportTests {
    private func makeCheckpoint(scope: ReplicaScope, id: UUID = UUID(), parentID: UUID? = nil,
                                entries: [FileEntry] = []) -> Checkpoint {
        Checkpoint(id: id, vaultID: scope.vaultID, parentID: parentID,
                   createdAt: Date(timeIntervalSince1970: 1_791_619_200.125),
                   message: "A local checkpoint", entries: entries)
    }

    private func file(_ path: String, bytes: Data) -> FileEntry {
        FileEntry(path: path, kind: .file, digest: ReplicaDigest.sha256(bytes), size: Int64(bytes.count))
    }

    private func expectError(_ expected: ReplicaError,
                             operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch {
            #expect(error as? ReplicaError == expected)
        }
    }

    @Test func sharedCheckpointSerializationAndBinaryObjects() async throws {
        let replica: any ReplicaTransport = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner-A", vaultID: UUID())
        let bytes = Data([0, 1, 255, 10])
        let digest = ReplicaDigest.sha256(bytes)
        let original = makeCheckpoint(scope: scope, entries: [
            FileEntry(path: "empty", kind: .directory),
            FileEntry(path: "attachments", kind: .directory),
            FileEntry(path: "attachments/原本.bin", kind: .file, digest: digest,
                      size: Int64(bytes.count), executable: true)
        ])
        let encoded = try VaultFormat.encode(original)
        let decoded = try VaultFormat.decode(Checkpoint.self, from: encoded)
        #expect(decoded == original)
        try await replica.uploadObject(bytes, digest: digest, in: scope)
        let request = ReplicaPublication(expectedParentID: nil, checkpoint: decoded)
        let requestWire = try VaultFormat.encode(request)
        let receipt = try await replica.publish(VaultFormat.decode(ReplicaPublication.self, from: requestWire), in: scope)
        #expect(receipt.manifestDigest == ReplicaDigest.sha256(encoded))
        #expect(try VaultFormat.decode(ReplicaPublicationReceipt.self, from: VaultFormat.encode(receipt)) == receipt)
        #expect(try await replica.head(in: scope) == original)
        #expect(try await replica.object(digest: digest, in: scope) == bytes)
    }

    @Test func incompleteRevisionDoesNotAdvanceHeadAndCanBeRetried() async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let parent = makeCheckpoint(scope: scope)
        _ = try await replica.publish(ReplicaPublication(expectedParentID: nil, checkpoint: parent), in: scope)
        let bytes = Data("not uploaded yet".utf8)
        let entry = file("note.md", bytes: bytes)
        let child = makeCheckpoint(scope: scope, parentID: parent.id, entries: [entry])
        let request = ReplicaPublication(expectedParentID: parent.id, checkpoint: child)
        await expectError(.missingObject(entry.digest!)) {
            _ = try await replica.publish(request, in: scope)
        }
        #expect(try await replica.head(in: scope) == parent)
        #expect(try await replica.checkpoint(id: child.id, in: scope) == nil)
        try await replica.uploadObject(bytes, digest: entry.digest!, in: scope)
        _ = try await replica.publish(request, in: scope)
        #expect(try await replica.head(in: scope) == child)
    }

    @Test func digestVerificationRejectsCorruptObject() async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let expected = ReplicaDigest.sha256(Data("original".utf8))
        let corrupt = Data("corrupted".utf8)
        await expectError(.digestMismatch(expected: expected, actual: ReplicaDigest.sha256(corrupt))) {
            try await replica.uploadObject(corrupt, digest: expected, in: scope)
        }
        #expect(try await replica.object(digest: expected, in: scope) == nil)
        #expect(try await replica.head(in: scope) == nil)
    }

    @Test(arguments: ["", "../object", String(repeating: "A", count: 64), String(repeating: "f", count: 63)])
    func malformedDigestsAreRejected(_ digest: String) async {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        await expectError(.invalidDigest(digest)) {
            try await replica.uploadObject(Data(), digest: digest, in: scope)
        }
    }

    @Test func sizeMismatchAndDuplicatePathsNeverPublish() async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let bytes = Data("hello".utf8)
        let good = file("note.md", bytes: bytes)
        try await replica.uploadObject(bytes, digest: good.digest!, in: scope)
        let bad = FileEntry(path: good.path, kind: .file, digest: good.digest, size: 100)
        await expectError(.objectSizeMismatch(path: good.path, expected: 100, actual: 5)) {
            _ = try await replica.publish(ReplicaPublication(expectedParentID: nil,
                checkpoint: makeCheckpoint(scope: scope, entries: [bad])), in: scope)
        }
        await expectError(.invalidCheckpoint("Duplicate path: note.md")) {
            _ = try await replica.publish(ReplicaPublication(expectedParentID: nil,
                checkpoint: makeCheckpoint(scope: scope, entries: [good, good])), in: scope)
        }
        #expect(try await replica.head(in: scope) == nil)
    }

    @Test(arguments: ["", "/absolute.md", "../escape.md", "a/../escape.md", "./note.md",
                      "a//note.md", "a/", "a\\note.md", "a\u{0000}note.md"])
    func unsafePathsNeverPublish(_ path: String) async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let checkpoint = makeCheckpoint(scope: scope, entries: [FileEntry(path: path, kind: .directory)])
        await expectError(.invalidCheckpoint("Unsafe relative path: \(path)")) {
            _ = try await replica.publish(ReplicaPublication(expectedParentID: nil, checkpoint: checkpoint), in: scope)
        }
        #expect(try await replica.head(in: scope) == nil)
    }

    @Test func fileCannotAlsoBeParentDirectory() async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let bytes = Data("same bytes".utf8)
        let a = file("folder", bytes: bytes)
        let b = file("folder/note.md", bytes: bytes)
        try await replica.uploadObject(bytes, digest: a.digest!, in: scope)
        await expectError(.invalidCheckpoint("A file is used as a directory: folder/note.md")) {
            _ = try await replica.publish(ReplicaPublication(expectedParentID: nil,
                checkpoint: makeCheckpoint(scope: scope, entries: [a, b])), in: scope)
        }
        #expect(try await replica.head(in: scope) == nil)
    }

    @Test func tenantAndVaultIsolationIncludesObjectsAndOperationIDs() async throws {
        let replica = InMemoryReplica()
        let vaultID = UUID()
        let a = ReplicaScope(tenantID: "tenant-A", vaultID: vaultID)
        let otherTenant = ReplicaScope(tenantID: "tenant-B", vaultID: vaultID)
        let otherVault = ReplicaScope(tenantID: "tenant-A", vaultID: UUID())
        let bytes = Data("private".utf8)
        let entry = file("private.md", bytes: bytes)
        let checkpoint = makeCheckpoint(scope: a, entries: [entry])
        let request = ReplicaPublication(expectedParentID: nil, checkpoint: checkpoint)
        try await replica.uploadObject(bytes, digest: entry.digest!, in: a)
        _ = try await replica.publish(request, in: a)
        for scope in [otherTenant, otherVault] {
            #expect(try await replica.object(digest: entry.digest!, in: scope) == nil)
            #expect(try await replica.head(in: scope) == nil)
            #expect(try await replica.checkpoint(id: checkpoint.id, in: scope) == nil)
            let scoped = ReplicaPublication(operationID: request.operationID, expectedParentID: nil,
                checkpoint: makeCheckpoint(scope: scope, entries: [entry]))
            await expectError(.missingObject(entry.digest!)) {
                _ = try await replica.publish(scoped, in: scope)
            }
            try await replica.uploadObject(bytes, digest: entry.digest!, in: scope)
            _ = try await replica.publish(scoped, in: scope)
        }
        #expect(try await replica.head(in: a) == checkpoint)
    }

    @Test func operationRetriesAreStableAfterHeadAdvancesAndRejectDifferentContent() async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let first = makeCheckpoint(scope: scope)
        let request = ReplicaPublication(expectedParentID: nil, checkpoint: first)
        let receipt = try await replica.publish(request, in: scope)
        let next = makeCheckpoint(scope: scope, parentID: first.id)
        _ = try await replica.publish(ReplicaPublication(expectedParentID: first.id, checkpoint: next), in: scope)
        #expect(try await replica.publish(request, in: scope) == receipt)
        #expect(try await replica.head(in: scope) == next)
        let changed = ReplicaPublication(operationID: request.operationID, expectedParentID: first.id,
                                         checkpoint: next)
        await expectError(.operationConflict(request.operationID)) {
            _ = try await replica.publish(changed, in: scope)
        }
        #expect(try await replica.head(in: scope) == next)
    }

    @Test func checkpointIdentityCannotBeReboundToNewContent() async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let first = makeCheckpoint(scope: scope)
        _ = try await replica.publish(ReplicaPublication(expectedParentID: nil, checkpoint: first), in: scope)
        let next = makeCheckpoint(scope: scope, parentID: first.id)
        _ = try await replica.publish(ReplicaPublication(expectedParentID: first.id, checkpoint: next), in: scope)
        let replacement = makeCheckpoint(scope: scope, id: first.id, parentID: next.id)
        await expectError(.checkpointConflict(first.id)) {
            _ = try await replica.publish(ReplicaPublication(expectedParentID: next.id, checkpoint: replacement), in: scope)
        }
        #expect(try await replica.checkpoint(id: first.id, in: scope) == first)
        #expect(try await replica.head(in: scope) == next)
    }

    @Test func concurrentExpectedParentPublicationHasExactlyOneWinner() async throws {
        let replica = InMemoryReplica()
        let scope = ReplicaScope(tenantID: "owner", vaultID: UUID())
        let parent = makeCheckpoint(scope: scope)
        _ = try await replica.publish(ReplicaPublication(expectedParentID: nil, checkpoint: parent), in: scope)
        let children = (0..<12).map { _ in makeCheckpoint(scope: scope, parentID: parent.id) }
        let results = await withTaskGroup(of: UUID?.self, returning: [UUID?].self) { group in
            for child in children {
                group.addTask {
                    do {
                        let receipt = try await replica.publish(
                            ReplicaPublication(expectedParentID: parent.id, checkpoint: child), in: scope)
                        return receipt.checkpointID
                    } catch let error as ReplicaError {
                        guard case .headConflict(let expected, let actual) = error else {
                            Issue.record("Unexpected rejection: \(error)")
                            return nil
                        }
                        #expect(expected == parent.id)
                        #expect(actual != parent.id)
                        return nil
                    } catch {
                        Issue.record("Unexpected error: \(error)")
                        return nil
                    }
                }
            }
            var results: [UUID?] = []
            for await result in group { results.append(result) }
            return results
        }
        let accepted = results.compactMap { $0 }
        #expect(accepted.count == 1)
        #expect(try await replica.head(in: scope)?.id == accepted.first)
        for child in children where child.id != accepted.first {
            #expect(try await replica.checkpoint(id: child.id, in: scope) == nil)
        }
    }

    @Test func invalidScopeAndWrongVaultCannotPublish() async throws {
        let replica = InMemoryReplica()
        let invalid = ReplicaScope(tenantID: "../tenant", vaultID: UUID())
        await expectError(.invalidScope) { _ = try await replica.head(in: invalid) }
        let scope = ReplicaScope(tenantID: "tenant", vaultID: UUID())
        let wrong = makeCheckpoint(scope: ReplicaScope(tenantID: "tenant", vaultID: UUID()))
        await expectError(.invalidCheckpoint("Checkpoint belongs to a different vault.")) {
            _ = try await replica.publish(ReplicaPublication(expectedParentID: nil, checkpoint: wrong), in: scope)
        }
        #expect(try await replica.head(in: scope) == nil)
    }
}
