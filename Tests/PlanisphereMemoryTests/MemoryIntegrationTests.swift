import Foundation
import XCTest
@testable import PlanisphereMemory

final class MemoryIntegrationTests: XCTestCase, @unchecked Sendable {
    func testScopesCannotMoveRecordsAndPausePreservesReadAndForget() throws {
        let root = URL(fileURLWithPath: "/private/tmp/memory-integration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MemoryStore(directory: root, profile: "profile")
        func request(_ action: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
            try store.handle(["action": action, "profile": "profile", "operation_id": UUID().uuidString].merging(fields) { _, new in new })
        }
        func commit(_ id: String, _ scope: String, revision: Int = 0) throws {
            _ = try request("commit", ["record_id": id, "scope": scope, "expected_revision": revision,
                "event_id": UUID().uuidString, "source_excerpt": "quoted source", "body": "saved fact", "kind": "claim", "attribution": "agent_interpretation"])
        }
        try commit("a", "project:a"); try commit("b", "project:b"); try commit("c", "personal")
        XCTAssertEqual((try request("resume", ["scope": "project:a"])["records"] as? [[String: Any]])?.count, 1)
        XCTAssertThrowsError(try request("inspect", ["record_id": "a", "scope": "project:b"]))
        XCTAssertThrowsError(try request("forget", ["record_id": "a", "scope": "project:b", "expected_revision": 1]))
        XCTAssertThrowsError(try commit("a", "project:b", revision: 1))
        _ = try request("configure", ["enabled": false])
        XCTAssertThrowsError(try commit("d", "personal"))
        XCTAssertEqual(try request("inspect", ["record_id": "a"])["body"] as? String, "saved fact")
        XCTAssertEqual(try request("forget", ["record_id": "a", "expected_revision": 1])["deletion_state"] as? String, "complete")
    }

    func testLocalBootstrapPersistsProfileWithoutAccountOrVault() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/memory-local-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        let input = Data(#"{"action":"status"}"#.utf8)
        let first = try await LocalMemory(root: root, helper: helper).request(input)
        let second = try await LocalMemory(root: root, helper: helper).request(input)
        let a = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        let b = try JSONSerialization.jsonObject(with: second) as! [String: Any]
        XCTAssertEqual(a["profile"] as? String, b["profile"] as? String)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("connection.json"))) as! [String: Any]
        XCTAssertEqual(config["helper_sha256"] as? String, digest(try Data(contentsOf: helper)))
        XCTAssertEqual(config["profile"] as? String, a["profile"] as? String)
    }

    func testHelperAliasIsRecordedAsCanonicalFilesystemPath() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/memory-alias-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let binary = base.appendingPathComponent("helper")
        try Data("synthetic executable bytes".utf8).write(to: binary)
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: binary)
        let root = base.appendingPathComponent("memory")
        _ = try await LocalMemory(root: root, helper: alias).request(Data(#"{"action":"status"}"#.utf8))
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("connection.json"))) as! [String: Any]
        XCTAssertEqual(config["helper_path"] as? String, binary.path)
    }
}
