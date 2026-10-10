import Foundation
import XCTest
@testable import PlanisphereGrapheine

final class GrapheineServiceTests: XCTestCase, @unchecked Sendable {
    func testRealBridgeScanUsesSelectedFolderAndTypedContract() async throws {
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("# Current\n".utf8).write(to: temporary.appendingPathComponent("Status.md"))
        try Data("# Older\n".utf8).write(to: temporary.appendingPathComponent("Archive/Status.md"))
        let service = GrapheineService()
        let scan = try await service.scan(vaultURL: temporary)
        XCTAssertEqual(scan.vaultPath, temporary.path)
        XCTAssertEqual(scan.notes, 2)
        XCTAssertEqual(scan.groups.count, 1)
        XCTAssertEqual(Set(scan.groups[0].members), Set(["Status.md", "Archive/Status.md"]))
        XCTAssertEqual(scan.authority.status, "notConfigured")
        XCTAssertEqual(scan.scope.kind, "markdown-discovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(".git").path))
    }

    func testScopedDiscoverySkipsExcludedFoldersAndSymlinksWithoutLosingIncludedNotes() async throws {
        let fixture = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("planisphere-scoped-scan-" + UUID().uuidString)
        let manager = FileManager.default
        for path in ["Archive", "Ignored", "node_modules", ".hidden-checkout", ".planisphere"] {
            try manager.createDirectory(at: fixture.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        defer { try? manager.removeItem(at: fixture) }
        for path in ["Status.md", "Archive/Status.md", "Ignored/Status.md", "node_modules/Status.md"] {
            try Data("# \(path)\n".utf8).write(to: fixture.appendingPathComponent(path))
        }
        try JSONSerialization.data(withJSONObject: ["excludedPaths": ["Ignored/"]])
            .write(to: fixture.appendingPathComponent(".planisphere/scope.json"))
        try manager.createSymbolicLink(at: fixture.appendingPathComponent(".hidden-checkout/loop"), withDestinationURL: fixture)
        try manager.createSymbolicLink(at: fixture.appendingPathComponent("linked.md"), withDestinationURL: fixture.appendingPathComponent("Status.md"))

        let scan = try await GrapheineService().scan(vaultURL: fixture)
        XCTAssertEqual(scan.notes, 2)
        XCTAssertEqual(Set(try XCTUnwrap(scan.groups.first).members), Set(["Status.md", "Archive/Status.md"]))
        XCTAssertTrue(Set(scan.scope.excludedPaths).isSuperset(of: ["Ignored/", "node_modules/", ".hidden-checkout/", "linked.md"]))
        XCTAssertTrue(scan.scope.appliedFilters.contains("Ignored/"))
        XCTAssertTrue(scan.scope.unsupportedFilters.isEmpty)
        XCTAssertGreaterThanOrEqual(scan.scope.excludedCount, 4)
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("Ignored/Status.md"), encoding: .utf8), "# Ignored/Status.md\n")
        XCTAssertFalse(manager.fileExists(atPath: fixture.appendingPathComponent(".git").path))
    }

    func testCoverageValidationRequiresBoundedCoherentScopeAndSafePaths() throws {
        let vault = URL(fileURLWithPath: "/private/tmp/scoped-fixture")
        var report = scanReport(vault: vault)
        let valid = try GrapheineService.validatedScan(JSONSerialization.data(withJSONObject: report), vaultURL: vault)
        XCTAssertEqual(valid.scope.excludedPaths, ["Ignored/"])

        report.removeValue(forKey: "scope")
        XCTAssertThrowsError(try GrapheineService.validatedScan(JSONSerialization.data(withJSONObject: report), vaultURL: vault))
        for changes: [String: Any] in [
            ["kind": "whole-vault"],
            ["excludedCount": 0],
            ["excludedCount": 2, "truncated": false],
            ["excludedPaths": ["../outside/"]],
            ["excludedPaths": ["/"]],
            ["excludedPaths": Array(repeating: "Ignored/", count: 101), "excludedCount": 101],
            ["appliedFilters": Array(repeating: "Ignored/", count: 101)]
        ] {
            report = scanReport(vault: vault)
            var scope = try XCTUnwrap(report["scope"] as? [String: Any])
            scope.merge(changes) { _, new in new }
            report["scope"] = scope
            XCTAssertThrowsError(try GrapheineService.validatedScan(JSONSerialization.data(withJSONObject: report), vaultURL: vault))
        }
    }

    func testUnavailableAuthorityCannotSupplyActionableQuestions() throws {
        let vault = URL(fileURLWithPath: "/private/tmp/scoped-fixture")
        var report = scanReport(vault: vault)
        report["authority"] = ["status": "unavailable", "message": "Full inventory held", "questions": [[
            "scope": "fixture", "question": "account", "values": ["Status.md"], "value": "Status.md",
            "state": "resolved", "writeState": "needs_exact_write_permission", "proofs": []
        ]]] as [String: Any]
        XCTAssertThrowsError(try GrapheineService.validatedScan(JSONSerialization.data(withJSONObject: report), vaultURL: vault))
        report["authority"] = ["status": "unavailable", "message": "Full inventory held", "questions": []] as [String: Any]
        let scan = try GrapheineService.validatedScan(JSONSerialization.data(withJSONObject: report), vaultURL: vault)
        XCTAssertEqual(scan.notes, 2)
        XCTAssertEqual(scan.authority.status, "unavailable")
        XCTAssertTrue(scan.authority.questions.isEmpty)
    }

    private func scanReport(vault: URL) -> [String: Any] {
        ["engineVersion": "fixture", "scannedAt": "2026-10-10T12:00:00+00:00", "vaultPath": vault.path,
         "notes": 2, "totalGroups": 0, "groups": [], "diagnostics": [], "fingerprint": String(repeating: "a", count: 64),
         "authority": ["status": "notConfigured", "questions": []] as [String: Any],
         "scope": ["kind": "markdown-discovery", "excludedPaths": ["Ignored/"], "excludedCount": 1,
                   "truncated": false, "appliedFilters": ["Ignored/"], "unsupportedFilters": [],
                   "limitations": ["Discovery is separate from write inventory."]] as [String: Any]]
    }

    func testQuestionIdentityDoesNotCollideAcrossScopes() throws {
        let data = Data("""
        [{"scope":"a/b","question":"c","values":[],"state":"needs_decision","proofs":[]},
         {"scope":"a","question":"b/c","values":[],"state":"needs_decision","proofs":[]}]
        """.utf8)
        let questions = try JSONDecoder().decode([PruningQuestion].self, from: data)
        XCTAssertNotEqual(questions[0].id, questions[1].id)
    }
    func testPacketPreservesRetirementAndExactOriginal() throws {
        let packet = try PruningPacket(data: packetData())
        XCTAssertEqual(packet.changes.count, 2)
        XCTAssertTrue(packet.changes[0].isRetired)
        XCTAssertEqual(packet.changes[0].before, "# Older\r\n")
        XCTAssertEqual(packet.changes[1].after, "[[current|older]]\n")
    }

    func testUnsafePathsAndMissingOriginalsRefuse() throws {
        XCTAssertThrowsError(try GrapheineService.validateRelativePath("../outside.md"))
        XCTAssertThrowsError(try GrapheineService.validateRelativePath("/absolute.md"))
        XCTAssertThrowsError(try GrapheineService.validateRelativePath("a//b.md"))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: packetData()) as? [String: Any])
        var inner = try XCTUnwrap(payload["packet"] as? [String: Any])
        inner["originals"] = [:] as [String: String]
        payload["packet"] = inner
        XCTAssertThrowsError(try PruningPacket(data: JSONSerialization.data(withJSONObject: payload)))
    }

    func testWorkingPreviewRefusesSymlinkAndBinary() async throws {
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("Original note".utf8).write(to: temporary.appendingPathComponent("source.md"))
        try Data([0, 1, 2]).write(to: temporary.appendingPathComponent("binary.md"))
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("link.md"), withDestinationURL: temporary.appendingPathComponent("source.md"))
        let service = GrapheineService()
        let note = try await service.readNote(vaultURL: temporary, path: "source.md")
        XCTAssertEqual(note, "Original note")
        let binary = try await service.readNote(vaultURL: temporary, path: "binary.md")
        XCTAssertNil(binary)
        do {
            _ = try await service.readNote(vaultURL: temporary, path: "link.md")
            XCTFail("A symbolic link must not be previewed")
        } catch {}
    }

    func testMissingEngineIsNotAnEmptySuccessfulScan() async throws {
        let missing = URL(fileURLWithPath: "/private/tmp/planisphere-missing-" + UUID().uuidString)
        let service = GrapheineService(helperURL: missing, engineURL: missing, pythonURL: URL(fileURLWithPath: "/usr/bin/python3"))
        do {
            _ = try await service.scan(vaultURL: missing)
            XCTFail("Missing engine must be a visible error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
    }

    private func packetData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "digest": String(repeating: "a", count: 64),
            "packet": [
                "schema": "grapheine-authority-v1", "vault": "/private/tmp/fixture", "scope": "fixture",
                "question": "account", "value": "current.md", "valid_until": "2026-10-11T12:00:00+00:00",
                "changes": ["older.md": NSNull(), "reader.md": "[[current|older]]\n"] as [String: Any],
                "originals": ["older.md": Data("# Older\r\n".utf8).base64EncodedString(),
                              "reader.md": Data("[[older]]\n".utf8).base64EncodedString()]
            ] as [String: Any]
        ])
    }
}
