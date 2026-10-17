import XCTest
import Foundation
import Darwin
@testable import PlanisphereCore

final class MarkdownCheckpointTests: XCTestCase, @unchecked Sendable {
    private typealias Fixture = VaultStoreTests.Fixture
    private struct Envelope<T: Codable>: Codable { let payload: T; let sha256: String }

    private func expectFailure<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected fail-closed behavior", file: file, line: line) }
        catch {}
    }

    private func paths(_ root: URL) throws -> Set<String> {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return Set(enumerator.compactMap { ($0 as? URL)?.path.dropFirst(root.path.count + 1).description })
    }

    func testMarkdownOnlyCaptureRestoreAndExportPreserveOnlyNotesAndAncestors() async throws {
        let f = try Fixture(); defer { f.clean() }
        let notes = ["Welcome.md": "# Welcome\n", "Research/Decisions/current.md": "# Decision\n", "Research/draft.md": "draft\n"]
        for (path, text) in notes { try f.write(path, text) }
        try f.write(".planisphere/scope.json", #"{"excludedPaths":["private.md","ignored/","*.tmp"]}"#)
        for path in ["private.md", "ignored/old.md", ".planisphere/plugin/readme.md", ".hidden/secret.md", "node_modules/readme.md", "__pycache__/generated.md", "Uppercase.MD", "attachments/image.png", "Research/diagram.pdf", "binary-only/nested/asset.bin"] {
            try f.write(path, "excluded")
        }
        try FileManager.default.createDirectory(at: f.source.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
        let outside = f.base.appendingPathComponent("external-pipe")
        XCTAssertEqual(mkfifo(outside.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("linked.md"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("linked-folder"), withDestinationURL: f.source.appendingPathComponent("Research"))
        XCTAssertEqual(mkfifo(f.source.appendingPathComponent("special.md").path, 0o600), 0)

        let vault = try await f.store.register(url: f.source)
        let plan = try await f.store.checkpointPlan(vaultID: vault.id, mode: .markdownOnly)
        let scope = try XCTUnwrap(plan.scope)
        XCTAssertEqual(scope.version, 4)
        XCTAssertEqual(scope.mode, .markdownOnly)
        XCTAssertEqual(scope.sourceConfigurationSHA256, VaultFS.hash(try Data(contentsOf: f.source.appendingPathComponent(".planisphere/scope.json"))))
        XCTAssertEqual(plan.fileCount, 3)
        XCTAssertEqual(plan.directoryCount, 2)
        XCTAssertEqual(plan.symbolicLinkCount, 0)
        XCTAssertEqual(plan.totalBytes, Int64(notes.values.reduce(0) { $0 + $1.utf8.count }))
        XCTAssertEqual(plan.unsupportedFilters, ["*.tmp"])
        XCTAssertTrue(plan.excludedPaths.contains { $0.path == "linked.md" && $0.reason.contains("Symbolic link") })
        XCTAssertTrue(plan.excludedPaths.contains { $0.path == "special.md" && $0.reason.contains("Special file") })
        let saved = try await f.store.createCheckpoint(vaultID: vault.id, message: "Markdown only", scope: scope)
        let expectedPaths = Set(notes.keys).union(["Research", "Research/Decisions"])
        XCTAssertEqual(Set(saved.entries.map(\.path)), expectedPaths)
        XCTAssertEqual(saved.formatVersion, 2)
        XCTAssertEqual(saved.captureScope, scope)
        XCTAssertEqual(saved.symbolicLinkCount, 0)

        // Restore/export must work without consulting the original settings or source.
        try FileManager.default.removeItem(at: f.source)
        let restored = try await f.store.restoreCopy(vaultID: vault.id, checkpointID: saved.id, destination: f.base.appendingPathComponent("Restored"))
        let restoredHistory = try await f.store.checkpoints(vaultID: restored.id)
        XCTAssertEqual(restoredHistory.first?.captureScope, scope)
        XCTAssertEqual(restoredHistory.first?.entries, saved.entries)
        let exported = try await f.store.exportVault(vaultID: vault.id, destination: f.base.appendingPathComponent("Export"))
        let exportFiles = exported.appendingPathComponent("files")
        XCTAssertEqual(try paths(restored.url), expectedPaths)
        XCTAssertEqual(try paths(exportFiles), expectedPaths)
        for (path, text) in notes {
            XCTAssertEqual(try Data(contentsOf: restored.url.appendingPathComponent(path)), Data(text.utf8))
            XCTAssertEqual(try Data(contentsOf: exportFiles.appendingPathComponent(path)), Data(text.utf8))
        }
        let manifestData = try Data(contentsOf: exported.appendingPathComponent("history/checkpoints/" + saved.id.uuidString + ".json"))
        let exportedManifest = try VaultFormat.decode(Envelope<Checkpoint>.self, from: manifestData)
        XCTAssertEqual(exportedManifest.payload.captureScope, scope)
        XCTAssertEqual(exportedManifest.sha256, VaultFS.hash(try VaultFormat.encode(exportedManifest.payload)))
    }

    func testExcludedFileEditsDoNotInvalidateNotesButSettingsRemainPinned() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("note.md", "note")
        try f.write("assets/image.bin", "old attachment")
        try f.write(".planisphere/scope.json", #"{"excludedPaths":[]}"#)
        let vault = try await f.store.register(url: f.source)
        let plan = try await f.store.checkpointPlan(vaultID: vault.id, mode: .markdownOnly)
        let imageURL = f.source.appendingPathComponent("assets/image.bin")
        await f.store.setCaptureValidationHook { try Data("changed attachment".utf8).write(to: imageURL) }
        let saved = try await f.store.createCheckpoint(vaultID: vault.id, message: "No attachment", scope: plan.scope)
        XCTAssertEqual(saved.entries.map(\.path), ["note.md"])

        let configURL = f.source.appendingPathComponent(".planisphere/scope.json")
        await f.store.setCaptureValidationHook { try Data(#"{"excludedPaths":["note.md"]}"#.utf8).write(to: configURL) }
        await expectFailure { try await f.store.createCheckpoint(vaultID: vault.id, message: "Stale config", scope: plan.scope) }
        await f.store.setCaptureValidationHook(nil)
        let history = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(history.map(\.id), [saved.id])
        await expectFailure { try await f.store.createCheckpoint(vaultID: vault.id, message: "Still stale", scope: plan.scope) }
    }

    func testForgedMarkdownManifestRejectsAttachmentsLinksAndUnrelatedDirectories() async throws {
        for scenario in ["attachment", "link", "unrelated-directory", "hidden-ancestor"] {
            let f = try Fixture(); defer { f.clean() }
            try f.write("note.md", "safe")
            let vault = try await f.store.register(url: f.source)
            let plan = try await f.store.checkpointPlan(vaultID: vault.id, mode: .markdownOnly)
            let saved = try await f.store.createCheckpoint(vaultID: vault.id, message: "Safe", scope: plan.scope)
            let original = try XCTUnwrap(saved.entries.first)
            var entries = saved.entries
            switch scenario {
            case "attachment": entries.append(FileEntry(path: "image.png", kind: .file, digest: original.digest, size: original.size))
            case "link": entries.append(FileEntry(path: "link.md", kind: .symbolicLink, digest: original.digest, size: original.size))
            case "unrelated-directory": entries.append(FileEntry(path: "empty", kind: .directory))
            default:
                entries.append(FileEntry(path: ".planisphere", kind: .directory))
                entries.append(FileEntry(path: ".planisphere/hidden.md", kind: .file, digest: original.digest, size: original.size))
            }
            let forged = Checkpoint(formatVersion: 2, id: saved.id, vaultID: saved.vaultID, parentID: nil,
                                    createdAt: saved.createdAt, message: saved.message, entries: entries, captureScope: saved.captureScope)
            try VaultFormat.encode(Envelope(payload: forged, sha256: VaultFS.hash(try VaultFormat.encode(forged))))
                .write(to: f.manifest(vault, saved))
            await expectFailure { try await f.store.checkpoints(vaultID: vault.id) }
            await expectFailure { try await f.store.restoreCopy(vaultID: vault.id, checkpointID: saved.id, destination: f.base.appendingPathComponent("No restore")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("No restore").path))
        }
    }

    func testVersionOneScopePreservesCanonicalEncodingAndMeaning() throws {
        // Golden bytes from the version-1 scope format: mode remains computed,
        // so decoding and re-encoding does not invalidate old envelope checksums.
        let original = Data("""
        {
          "excludedPaths" : [
            "build/",
            "private.md"
          ],
          "sourceConfigurationSHA256" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "version" : 1
        }
        """.utf8)
        let scope = try VaultFormat.decode(CheckpointScope.self, from: original)
        try scope.validate()
        XCTAssertEqual(scope.mode, .vaultContent)
        XCTAssertEqual(try VaultFormat.encode(scope), original)
        XCTAssertFalse(scope.excludes("image.png", isDirectory: false))
        XCTAssertFalse(scope.excludes("link", isDirectory: false, isSymbolicLink: true, isRegularFile: false))
        XCTAssertFalse(scope.excludes(".obsidian", isDirectory: true))
    }
}
