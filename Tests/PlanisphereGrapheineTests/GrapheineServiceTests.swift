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
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(".git").path))
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
