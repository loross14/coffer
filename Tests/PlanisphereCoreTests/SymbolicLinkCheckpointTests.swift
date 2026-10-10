import XCTest
import Foundation
import Darwin
@testable import PlanisphereCore

final class SymbolicLinkCheckpointTests: XCTestCase, @unchecked Sendable {
    private typealias Fixture = VaultStoreTests.Fixture

    private func link(_ target: Data, at url: URL) throws {
        var bytes = Array(target); bytes.append(0)
        let result = bytes.withUnsafeBytes {
            symlinkat($0.baseAddress!.assumingMemoryBound(to: CChar.self), AT_FDCWD, url.path)
        }
        guard result == 0 else { throw VaultFS.unavailable("Test symlink creation failed") }
    }

    private func target(at url: URL) throws -> Data {
        try VaultFS.readSymbolicLink(VaultFS.directory(url.deletingLastPathComponent()), url.lastPathComponent)
    }

    private func expectFailure<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected fail-closed behavior", file: file, line: line) }
        catch {}
    }

    func testLinksPreserveExactTargetsWithoutReadingThemThroughRestoreAndExport() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("notes/local.md", "local bytes")
        let vault = try await f.store.register(url: f.source)
        let first = try await f.store.createCheckpoint(vaultID: vault.id, message: "Version 1")
        XCTAssertEqual(first.formatVersion, 1)
        let outside = f.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        // Traversing this target would make capture fail on the FIFO.
        XCTAssertEqual(mkfifo(outside.appendingPathComponent("pipe").path, 0o600), 0)
        let externalBytes = Data("not inside the selected vault".utf8)
        try externalBytes.write(to: outside.appendingPathComponent("external.md"))
        let links: [String: Data] = [
            "relative": Data("notes/local.md".utf8),
            "absolute": Data(outside.path.utf8),
            "broken": Data("../missing-target".utf8),
            "opaque": Data([0x66, 0xFF, 0x6F])
        ]
        for (name, data) in links { try link(data, at: f.source.appendingPathComponent(name)) }
        let second = try await f.store.createCheckpoint(vaultID: vault.id, message: "Links")
        XCTAssertEqual(second.formatVersion, 2)
        XCTAssertEqual(second.parentID, first.id)
        XCTAssertEqual(second.fileCount, 1)
        XCTAssertEqual(second.symbolicLinkCount, 4)
        XCTAssertFalse(second.entries.contains { $0.path.hasPrefix("absolute/") })
        XCTAssertFalse(second.entries.contains { $0.digest == VaultFS.hash(externalBytes) })
        for (name, bytes) in links {
            let entry = try XCTUnwrap(second.entries.first { $0.path == name })
            XCTAssertEqual(entry.kind, .symbolicLink)
            XCTAssertEqual(entry.size, Int64(bytes.count))
            XCTAssertEqual(try Data(contentsOf: f.storeURL.appendingPathComponent("objects/" + entry.digest!)), bytes)
        }
        let text = try await f.store.text(vaultID: vault.id, checkpointID: second.id, path: "absolute")
        XCTAssertEqual(text, outside.path)
        let opaqueText = try await f.store.text(vaultID: vault.id, checkpointID: second.id, path: "opaque")
        XCTAssertNil(opaqueText)

        let reopened = try VaultStore(rootURL: f.storeURL)
        let saved = try await reopened.checkpoints(vaultID: vault.id)
        XCTAssertEqual(saved.map(\.id), [second.id, first.id])
        try FileManager.default.removeItem(at: f.source)
        let restoredURL = f.base.appendingPathComponent("Restored")
        let restored = try await reopened.restoreCopy(vaultID: vault.id, checkpointID: second.id, destination: restoredURL)
        let restoredHistory = try await reopened.checkpoints(vaultID: restored.id)
        XCTAssertEqual(restoredHistory.first?.formatVersion, 2)
        XCTAssertEqual(restoredHistory.first?.entries, second.entries)
        let exported = try await reopened.exportVault(vaultID: vault.id, destination: f.base.appendingPathComponent("Export"))
        for (name, bytes) in links {
            XCTAssertEqual(try target(at: restoredURL.appendingPathComponent(name)), bytes)
            XCTAssertEqual(try target(at: exported.appendingPathComponent("files/" + name)), bytes)
            XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("history/objects/" + VaultFS.hash(bytes))), bytes)
        }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("external.md")), externalBytes)
    }

    func testLinkChangesDuringCaptureDoNotPublish() async throws {
        let f = try Fixture(); defer { f.clean() }
        let path = f.source.appendingPathComponent("link")
        try link(Data("first-target".utf8), at: path)
        let vault = try await f.store.register(url: f.source)
        let original = try await f.store.createCheckpoint(vaultID: vault.id, message: "Original")
        await f.store.setCaptureValidationHook {
            guard unlink(path.path) == 0, symlink("second-target", path.path) == 0 else {
                throw VaultStoreError.unavailable("Test link mutation failed")
            }
        }
        await expectFailure { try await f.store.createCheckpoint(vaultID: vault.id, message: "Must fail") }
        await f.store.setCaptureValidationHook(nil)
        let history = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(history.map(\.id), [original.id])
        let updated = try await f.store.createCheckpoint(vaultID: vault.id, message: "Changed link")
        let changes = try await f.store.changes(vaultID: vault.id, from: original.id, to: updated.id)
        XCTAssertEqual(changes.map(\.kind), [.modified])
        let text = try await f.store.text(vaultID: vault.id, checkpointID: updated.id, path: "link")
        XCTAssertEqual(text, "second-target")
    }

    private struct Envelope<T: Codable>: Codable { let payload: T; let sha256: String }
    private func replace(_ checkpoint: Checkpoint, fixture: Fixture, vault: VaultRecord) throws {
        let bytes = try VaultFormat.encode(checkpoint)
        try VaultFormat.encode(Envelope(payload: checkpoint, sha256: VaultFS.hash(bytes)))
            .write(to: fixture.manifest(vault, checkpoint))
    }

    func testInvalidLinkTargetsVersionAndLinkAncestorsAreRejected() async throws {
        for scenario in ["nul", "empty", "old-version", "link-parent"] {
            let f = try Fixture(); defer { f.clean() }
            try f.write("note", "safe")
            let vault = try await f.store.register(url: f.source)
            let saved = try await f.store.createCheckpoint(vaultID: vault.id, message: "Safe")
            let targetBytes = scenario == "nul" ? Data([65, 0, 66]) : scenario == "empty" ? Data() : Data("../outside".utf8)
            let digest = VaultFS.hash(targetBytes)
            try targetBytes.write(to: f.storeURL.appendingPathComponent("objects/" + digest))
            // Sharing with a regular object must not bypass link-specific validation.
            var entries = [FileEntry(path: "a-file", kind: .file, digest: digest, size: Int64(targetBytes.count)),
                           FileEntry(path: "link", kind: .symbolicLink, digest: digest, size: Int64(targetBytes.count))]
            if scenario == "link-parent" {
                entries.append(FileEntry(path: "link/child", kind: .file, digest: saved.entries[0].digest, size: 4))
            }
            let forged = Checkpoint(formatVersion: scenario == "old-version" ? 1 : 2, id: saved.id,
                                    vaultID: saved.vaultID, parentID: nil, message: saved.message, entries: entries)
            try replace(forged, fixture: f, vault: vault)
            await expectFailure { try await f.store.checkpoints(vaultID: vault.id) }
            await expectFailure { try await f.store.restoreCopy(vaultID: vault.id, checkpointID: saved.id,
                                                               destination: f.base.appendingPathComponent("No restore")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("No restore").path))
            XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("note"), encoding: .utf8), "safe")
        }
    }

    func testReviewedContentScopePreservesIncludedBytesAndRecordsExclusions() async throws {
        let f = try Fixture(); defer { f.clean() }
        let config = Data("{\"excludedPaths\":[\"ignored/\",\"ignored-file.txt\"]}".utf8)
        try f.write(".planisphere/scope.json", config)
        try f.write(".planisphere/plugins/plugin/data.json", "settings")
        try f.write("assets/picture.bin", Data([0, 255, 10]))
        try f.write("note.md", "retained")
        try f.write(".env", "included hidden file")
        try f.write("ignored/deep/old.md", "excluded by reviewed filter")
        try f.write("ignored-file.txt", "excluded by reviewed filter")
        try f.write(".build/cache", "excluded hidden directory")
        try f.write("node_modules/pkg/index.js", "excluded dependencies")
        // Excluding the containing folder must not inspect or follow its contents.
        XCTAssertEqual(mkfifo(f.source.appendingPathComponent(".build/pipe").path, 0o600), 0)
        try link(Data("ignored/deep/old.md".utf8), at: f.source.appendingPathComponent("reference"))
        let vault = try await f.store.register(url: f.source)
        let plan = try await f.store.checkpointPlan(vaultID: vault.id, mode: .vaultContent)
        let scope = try XCTUnwrap(plan.scope)
        XCTAssertEqual(Set(plan.excludedPaths.map(\.path)), Set(["ignored", "ignored-file.txt", ".build", "node_modules"]))
        let saved = try await f.store.createCheckpoint(vaultID: vault.id, message: "Reviewed content", scope: scope)
        XCTAssertEqual(saved.formatVersion, 2)
        XCTAssertEqual(saved.captureScope, scope)
        XCTAssertEqual(saved.fileCount, plan.fileCount)
        XCTAssertEqual(saved.symbolicLinkCount, plan.symbolicLinkCount)
        let paths = Set(saved.entries.map(\.path))
        XCTAssertTrue(paths.contains(".planisphere/plugins/plugin/data.json"))
        XCTAssertTrue(paths.contains("assets/picture.bin"))
        XCTAssertTrue(paths.contains(".env"))
        XCTAssertFalse(paths.contains("ignored"))
        XCTAssertFalse(paths.contains(".build"))
        let restored = try await f.store.restoreCopy(vaultID: vault.id, checkpointID: saved.id,
                                                     destination: f.base.appendingPathComponent("Scoped restore"))
        let history = try await f.store.checkpoints(vaultID: restored.id)
        XCTAssertEqual(history[0].captureScope, scope)
        XCTAssertEqual(history[0].formatVersion, 2)
        XCTAssertEqual(try Data(contentsOf: restored.url.appendingPathComponent(".planisphere/scope.json")), config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.url.appendingPathComponent("ignored").path))
        XCTAssertEqual(try target(at: restored.url.appendingPathComponent("reference")), Data("ignored/deep/old.md".utf8))
        let exported = try await f.store.exportVault(vaultID: vault.id, destination: f.base.appendingPathComponent("Scoped export"))
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("files/assets/picture.bin")), Data([0, 255, 10]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("files/node_modules").path))
        // Full-folder behavior remains explicit and refuses the FIFO instead of omitting it.
        await expectFailure { try await f.store.createCheckpoint(vaultID: vault.id, message: "Full folder") }
        try f.write(".planisphere/scope.json", "{\"excludedPaths\":[\"ignored/\",\"assets/\"]}")
        await expectFailure { try await f.store.createCheckpoint(vaultID: vault.id, message: "Stale scope", scope: scope) }
        let unchanged = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(unchanged.map(\.id), [saved.id])
    }

    func testExcludedConfigurationRemainsPinnedThroughCapture() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write(".planisphere/scope.json", "{\"excludedPaths\":[\".planisphere/scope.json\"]}")
        try f.write("note.md", "included")
        let vault = try await f.store.register(url: f.source)
        let plan = try await f.store.checkpointPlan(vaultID: vault.id, mode: .vaultContent)
        let scope = try XCTUnwrap(plan.scope)
        let configurationURL = f.source.appendingPathComponent(".planisphere/scope.json")
        let changed = Data("{\"excludedPaths\":[\".planisphere/scope.json\"],\"changed\":true}".utf8)
        await f.store.setCaptureValidationHook { try changed.write(to: configurationURL) }
        await expectFailure { try await f.store.createCheckpoint(vaultID: vault.id, message: "Configuration changed", scope: scope) }
        await f.store.setCaptureValidationHook(nil)
        let history = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(try Data(contentsOf: configurationURL), changed)
        let updatedPlan = try await f.store.checkpointPlan(vaultID: vault.id, mode: .vaultContent)
        let saved = try await f.store.createCheckpoint(vaultID: vault.id, message: "Reviewed again", scope: updatedPlan.scope)
        XCTAssertFalse(saved.entries.contains { $0.path == ".planisphere/scope.json" })
        XCTAssertNotEqual(saved.captureScope, scope)
    }
}
