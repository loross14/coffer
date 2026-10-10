import XCTest
import Foundation
import Darwin
@testable import PlanisphereCore

final class VaultStoreTests: XCTestCase, @unchecked Sendable {
    struct Fixture {
        let base: URL
        let source: URL
        let storeURL: URL
        let store: VaultStore
        init() throws {
            base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("PlanisphereTests-" + UUID().uuidString, isDirectory: true)
            source = base.appendingPathComponent("Working", isDirectory: true)
            storeURL = base.appendingPathComponent("History", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            store = try VaultStore(rootURL: storeURL)
        }
        func clean() { try? FileManager.default.removeItem(at: base) }
        func write(_ path: String, _ bytes: Data) throws {
            let target = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        func write(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }
        func manifest(_ vault: VaultRecord, _ checkpoint: Checkpoint) -> URL {
            storeURL.appendingPathComponent("vaults/\(vault.id.uuidString)/checkpoints/\(checkpoint.id.uuidString).json")
        }
    }

    private func assertFailure<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Operation should fail closed", file: file, line: line) }
        catch { }
    }

    func testFidelityRestoreExportAndRestartWithoutWorkingFolder() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("Note.md", "first\n")
        try f.write(".obsidian/app.json", "{\"hidden\":true}")
        let binary = Data([0, 255, 42, 19, 0])
        try f.write("attachments/photo.bin", binary)
        try f.write("run.sh", "#!/bin/sh\n")
        XCTAssertEqual(chmod(f.source.appendingPathComponent("run.sh").path, 0o700), 0)
        try FileManager.default.createDirectory(at: f.source.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
        let vault = try await f.store.register(url: f.source)
        let first = try await f.store.createCheckpoint(vaultID: vault.id, message: "Initial")
        XCTAssertTrue(first.entries.contains { $0.path == ".obsidian/app.json" })
        XCTAssertTrue(first.entries.contains { $0.path == "empty/nested" && $0.kind == .directory })
        XCTAssertTrue(first.entries.contains { $0.path == "run.sh" && $0.executable })
        try f.write("Note.md", "second\n")
        let second = try await f.store.createCheckpoint(vaultID: vault.id, message: "Updated")
        let reopened = try VaultStore(rootURL: f.storeURL)
        let history = try await reopened.checkpoints(vaultID: vault.id)
        XCTAssertEqual(history.map(\.id), [second.id, first.id])
        let text = try await reopened.text(vaultID: vault.id, checkpointID: first.id, path: "Note.md")
        XCTAssertEqual(text, "first\n")
        let binaryText = try await reopened.text(vaultID: vault.id, checkpointID: first.id, path: "attachments/photo.bin")
        XCTAssertNil(binaryText)
        let restoredURL = f.base.appendingPathComponent("Restored")
        let restored = try await reopened.restoreCopy(vaultID: vault.id, checkpointID: first.id, destination: restoredURL)
        XCTAssertNotEqual(restored.id, vault.id)
        XCTAssertEqual(restored.restoredFrom, RestorationOrigin(vaultID: vault.id, checkpointID: first.id))
        XCTAssertEqual(try String(contentsOf: restoredURL.appendingPathComponent("Note.md"), encoding: .utf8), "first\n")
        XCTAssertEqual(try Data(contentsOf: restoredURL.appendingPathComponent("attachments/photo.bin")), binary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.appendingPathComponent("empty/nested").path))
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("Note.md"), encoding: .utf8), "second\n")
        let restoredHistory = try await reopened.checkpoints(vaultID: restored.id)
        XCTAssertEqual(restoredHistory.count, 1)
        XCTAssertEqual(restoredHistory[0].entries, first.entries)
        // Portability cannot require the old device's working folder.
        try FileManager.default.removeItem(at: f.source)
        let export = try await reopened.exportVault(vaultID: vault.id, destination: f.base.appendingPathComponent("Export"))
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("files/Note.md"), encoding: .utf8), "second\n")
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("files/.obsidian/app.json")), Data("{\"hidden\":true}".utf8))
        let manifests = try FileManager.default.contentsOfDirectory(atPath: export.appendingPathComponent("history/checkpoints").path)
        XCTAssertEqual(Set(manifests), Set([first.id, second.id].map { $0.uuidString + ".json" }))
        for entry in first.entries + second.entries where entry.kind == .file {
            let data = try Data(contentsOf: export.appendingPathComponent("history/objects/" + entry.digest!))
            XCTAssertEqual(VaultFS.hash(data), entry.digest)
        }
        let unchangedHistory = try await reopened.checkpoints(vaultID: vault.id)
        XCTAssertEqual(unchangedHistory.map(\.id), [second.id, first.id])
    }

    func testChangesDeletionAndUnsavedFilesExcludedFromExport() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("note.md", "old")
        try f.write("deleted.md", "keep in history")
        let v = try await f.store.register(url: f.source)
        let a = try await f.store.createCheckpoint(vaultID: v.id, message: "A")
        try f.write("note.md", "new")
        try f.write("added.md", "added")
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("deleted.md"))
        let b = try await f.store.createCheckpoint(vaultID: v.id, message: "B")
        let diff = try await f.store.changes(vaultID: v.id, from: a.id, to: b.id)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: diff.map { ($0.path, $0.kind.rawValue) }), ["note.md":"modified", "added.md":"added", "deleted.md":"deleted"])
        try f.write("note.md", "unsaved")
        let export = try await f.store.exportVault(vaultID: v.id, destination: f.base.appendingPathComponent("Export"))
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("files/note.md"), encoding: .utf8), "new")
        let oldText = try await f.store.text(vaultID: v.id, checkpointID: a.id, path: "deleted.md")
        XCTAssertEqual(oldText, "keep in history")
    }

    func testCreateArchiveReactivatePreservesIdentityAndHistory() async throws {
        let f = try Fixture(); defer { f.clean() }
        let v = try await f.store.create(at: f.base.appendingPathComponent("New vault"))
        let empty = try await f.store.checkpoints(vaultID: v.id)
        XCTAssertTrue(empty.isEmpty)
        await assertFailure { try await f.store.exportVault(vaultID: v.id, destination: f.base.appendingPathComponent("Too early")) }
        let checkpoint = try await f.store.createCheckpoint(vaultID: v.id, message: "Empty vault")
        try await f.store.archiveVault(v.id)
        let active = try await f.store.vaults()
        XCTAssertTrue(active.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v.path))
        let archived = try await f.store.vaults(includeArchived: true)
        XCTAssertTrue(archived[0].archived)
        let readded = try await f.store.register(url: v.url)
        XCTAssertEqual(readded.id, v.id)
        XCTAssertFalse(readded.archived)
        let history = try await f.store.checkpoints(vaultID: v.id)
        XCTAssertEqual(history.map(\.id), [checkpoint.id])
    }

    func testMissingAndCorruptRegistryNeverResetsStore() async throws {
        for delete in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            try f.write("note.md", "retained")
            let v = try await f.store.register(url: f.source)
            let cp = try await f.store.createCheckpoint(vaultID: v.id, message: "Save")
            let registry = f.storeURL.appendingPathComponent("registry.json")
            if delete { try FileManager.default.removeItem(at: registry) }
            else { try Data("broken".utf8).write(to: registry) }
            XCTAssertThrowsError(try VaultStore(rootURL: f.storeURL))
            await assertFailure { try await f.store.vaults() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.manifest(v, cp).path))
            XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("note.md"), encoding: .utf8), "retained")
        }
    }

    func testMissingHeadCannotSilentlyStartAnotherHistory() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("note.md", "retained")
        let v = try await f.store.register(url: f.source)
        let cp = try await f.store.createCheckpoint(vaultID: v.id, message: "First")
        try FileManager.default.removeItem(at: f.storeURL.appendingPathComponent("vaults/\(v.id.uuidString)/head.json"))
        await assertFailure { try await f.store.checkpoints(vaultID: v.id) }
        await assertFailure { try await f.store.createCheckpoint(vaultID: v.id, message: "Must fail") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.manifest(v, cp).path))
    }

    func testCorruptObjectCannotReadRestoreOrExtendHistory() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("note.md", "retained")
        let v = try await f.store.register(url: f.source)
        let cp = try await f.store.createCheckpoint(vaultID: v.id, message: "First")
        let digest = cp.entries.first!.digest!
        try Data("damaged".utf8).write(to: f.storeURL.appendingPathComponent("objects/" + digest))
        await assertFailure { try await f.store.text(vaultID: v.id, checkpointID: cp.id, path: "note.md") }
        await assertFailure { try await f.store.restoreCopy(vaultID: v.id, checkpointID: cp.id, destination: f.base.appendingPathComponent("No restore")) }
        await assertFailure { try await f.store.createCheckpoint(vaultID: v.id, message: "Must fail") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("No restore").path))
    }

    private struct Envelope<T: Codable>: Codable { let payload: T; let sha256: String }
    private func replaceManifest(_ cp: Checkpoint, at url: URL, entries: [FileEntry]) throws {
        let replacement = Checkpoint(id: cp.id, vaultID: cp.vaultID, parentID: cp.parentID, createdAt: cp.createdAt, message: cp.message, entries: entries)
        let envelope = Envelope(payload: replacement, sha256: VaultFS.hash(try VaultFormat.encode(replacement)))
        try VaultFormat.encode(envelope).write(to: url)
    }

    func testManifestTraversalAliasesAndOverflowAreRejectedBeforeRestore() async throws {
        let badEntries: [[FileEntry]] = [
            [FileEntry(path: "../outside", kind: .directory)],
            [FileEntry(path: "/outside", kind: .directory)],
            [FileEntry(path: "Folder", kind: .directory), FileEntry(path: "folder", kind: .directory)],
            [FileEntry(path: "caf\u{00e9}", kind: .directory), FileEntry(path: "cafe\u{0301}", kind: .directory)],
            [FileEntry(path: "a", kind: .file, digest: String(repeating: "0", count: 64), size: Int64.max), FileEntry(path: "b", kind: .file, digest: String(repeating: "0", count: 64), size: 1)]
        ]
        for entries in badEntries {
            let f = try Fixture(); defer { f.clean() }
            let v = try await f.store.register(url: f.source)
            let cp = try await f.store.createCheckpoint(vaultID: v.id, message: "Empty")
            try replaceManifest(cp, at: f.manifest(v, cp), entries: entries)
            await assertFailure { try await f.store.restoreCopy(vaultID: v.id, checkpointID: cp.id, destination: f.base.appendingPathComponent("Unsafe")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("Unsafe").path))
        }
    }

    func testSourceAndDestinationSymlinksAndSpecialFilesAreRejected() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("note.md", "original")
        let alias = f.base.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.source)
        await assertFailure { try await f.store.register(url: alias) }
        let v = try await f.store.register(url: f.source)
        let cp = try await f.store.createCheckpoint(vaultID: v.id, message: "Safe")
        let linkedFile = f.source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: f.base)
        await assertFailure { try await f.store.createCheckpoint(vaultID: v.id, message: "Unsafe link") }
        try FileManager.default.removeItem(at: linkedFile)
        let fifo = f.source.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        await assertFailure { try await f.store.createCheckpoint(vaultID: v.id, message: "Unsafe special file") }
        await assertFailure { try await f.store.restoreCopy(vaultID: v.id, checkpointID: cp.id, destination: alias.appendingPathComponent("Child")) }
        await assertFailure { try await f.store.exportVault(vaultID: v.id, destination: alias) }
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("note.md"), encoding: .utf8), "original")
    }

    func testExistingDestinationsAreNeverOverwritten() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("note.md", "checkpoint")
        let v = try await f.store.register(url: f.source)
        let cp = try await f.store.createCheckpoint(vaultID: v.id, message: "Save")
        let destination = f.base.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await assertFailure { try await f.store.restoreCopy(vaultID: v.id, checkpointID: cp.id, destination: destination) }
        await assertFailure { try await f.store.exportVault(vaultID: v.id, destination: destination) }
        // Even a new empty directory appearing after staging cannot be replaced.
        let parent = try VaultFS.directory(f.base)
        _ = try VaultFS.childDirectory(parent, "staging", create: true)
        XCTAssertThrowsError(try VaultFS.publishDirectory(parent: parent, temporary: "staging", destination: "Existing"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("staging").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testHistoryMustBeOutsideVaultAndAliasesCannotRegisterTwice() async throws {
        let f = try Fixture(); defer { f.clean() }
        await assertFailure { try await f.store.register(url: f.base) }
        await assertFailure { try await f.store.register(url: f.storeURL) }
        let v = try await f.store.register(url: f.source)
        await assertFailure { try await f.store.create(at: f.source.appendingPathComponent("Nested")) }
        // Case-insensitive filesystems accept this path; if supported it must reuse identity.
        let alternate = f.source.deletingLastPathComponent().appendingPathComponent("working")
        if FileManager.default.fileExists(atPath: alternate.path) {
            let same = try await f.store.register(url: alternate)
            XCTAssertEqual(same.id, v.id)
            let rootCase = f.storeURL.deletingLastPathComponent().appendingPathComponent("history")
            await assertFailure { try await f.store.register(url: rootCase) }
        }
        // The Data-volume alias is present on modern macOS; it must not bypass containment.
        let firmlink = URL(fileURLWithPath: "/System/Volumes/Data" + f.source.path)
        if FileManager.default.fileExists(atPath: firmlink.path) {
            let same = try await f.store.register(url: firmlink)
            XCTAssertEqual(same.id, v.id)
            let rootAlias = URL(fileURLWithPath: "/System/Volumes/Data" + f.storeURL.path)
            await assertFailure { try await f.store.register(url: rootAlias) }
        }
    }

    func testChangedCaptureDoesNotPublishAndRetryUsesOriginalParent() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("note.md", "first")
        let v = try await f.store.register(url: f.source)
        let a = try await f.store.createCheckpoint(vaultID: v.id, message: "A")
        let note = f.source.appendingPathComponent("note.md")
        await f.store.setCaptureValidationHook { try Data("concurrent edit".utf8).write(to: note) }
        do {
            _ = try await f.store.createCheckpoint(vaultID: v.id, message: "Must not publish")
            XCTFail("Expected concurrent-edit rejection")
        } catch VaultStoreError.changedDuringCapture { }
        await f.store.setCaptureValidationHook(nil)
        let history = try await f.store.checkpoints(vaultID: v.id)
        XCTAssertEqual(history.map(\.id), [a.id])
        let b = try await f.store.createCheckpoint(vaultID: v.id, message: "B")
        XCTAssertEqual(b.parentID, a.id)
        let currentText = try await f.store.text(vaultID: v.id, checkpointID: b.id, path: "note.md")
        XCTAssertEqual(currentText, "concurrent edit")
    }

    func testMetadataSizeRejectedBeforeReplacingReadableFile() throws {
        let f = try Fixture(); defer { f.clean() }
        let root = try VaultFS.directory(f.storeURL)
        let old = try Data(contentsOf: f.storeURL.appendingPathComponent("registry.json"))
        XCTAssertThrowsError(try VaultFS.atomicData(Data(repeating: 42, count: 129), parent: root, name: "registry.json", replace: true, maximumBytes: 128))
        XCTAssertEqual(try Data(contentsOf: f.storeURL.appendingPathComponent("registry.json")), old)
        XCTAssertThrowsError(try VaultFS.atomicData(Data(repeating: 42, count: 129), parent: root, name: "oversized.json", replace: false, maximumBytes: 128))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.storeURL.appendingPathComponent("oversized.json").path))
    }

    func testLargeBinaryIsHashedAndTextPreviewBounded() async throws {
        let f = try Fixture(); defer { f.clean() }
        let bytes = Data(repeating: 87, count: 3 * 1024 * 1024 + 7)
        try f.write("large.bin", bytes)
        let v = try await f.store.register(url: f.source)
        let cp = try await f.store.createCheckpoint(vaultID: v.id, message: "Binary")
        XCTAssertEqual(cp.entries.first?.size, Int64(bytes.count))
        XCTAssertEqual(cp.entries.first?.digest, VaultFS.hash(bytes))
        let preview = try await f.store.text(vaultID: v.id, checkpointID: cp.id, path: "large.bin")
        XCTAssertNil(preview)
    }

    func testLockChildProcessHelper() throws {
        guard let path = ProcessInfo.processInfo.environment["PLANISPHERE_LOCK_TEST_PATH"] else { return }
        let descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else { throw VaultStoreError.unavailable("Test lock unavailable") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw VaultStoreError.busy }
        defer { flock(descriptor, LOCK_UN) }
        try FileHandle.standardOutput.write(contentsOf: Data("LOCK_READY\n".utf8))
        _ = try FileHandle.standardInput.read(upToCount: 1)
    }

    func testAnotherProcessOwnsLockUntilReleased() async throws {
        let f = try Fixture(); defer { f.clean() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "PlanisphereCoreTests.VaultStoreTests/testLockChildProcessHelper", Bundle(for: VaultStoreTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PLANISPHERE_LOCK_TEST_PATH"] = f.storeURL.appendingPathComponent(".lock").path
        child.environment = environment
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data([1]))
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        var captured = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            captured.append(byte)
            if captured.suffix(11) == Data("LOCK_READY\n".utf8) { break }
        }
        XCTAssertTrue(String(decoding: captured, as: UTF8.self).contains("LOCK_READY"), String(decoding: captured, as: UTF8.self))
        do { _ = try await f.store.vaults(); XCTFail("Expected other-process lock rejection") }
        catch VaultStoreError.busy { }
    }
}
