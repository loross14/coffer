import CryptoKit
import Foundation
import XCTest
@testable import PlanisphereConnection

final class LocalWorkReaderTests: XCTestCase {
    func testCaptureScopeHashExpiryAndSymlinksAreEnforced() throws {
        let home = URL(fileURLWithPath: "/private/tmp/local-work-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let captures = home.appendingPathComponent(".local/state/planisphere/codex/fixture/conversation-memory")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let now = Date()
        func write(_ name: String, cwd: String, text: String = "Read this 🧭", hash: String? = nil, age: Double = 0, mode: Int = 0o600) throws -> URL {
            let message: [String: Any] = ["sequence": 1, "turn_id": name, "role": "user", "content": text,
                "characters": text.unicodeScalars.count, "sha256": hash ?? SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), "observed_at": now.timeIntervalSince1970 - age]
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "host": "codex", "session_id": "session", "cwd": cwd, "messages": [message]])
            let file = captures.appendingPathComponent(name + ".json")
            try data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            return file
        }
        _ = try write("good", cwd: project.path)
        _ = try write("other-project", cwd: home.path)
        _ = try write("tampered", cwd: project.path, hash: "bad")
        _ = try write("expired", cwd: project.path, age: 86401)
        _ = try write("public", cwd: project.path, mode: 0o644)
        let link = try write("symlink", cwd: project.path)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: captures.appendingPathComponent("good.json"))
        let result = LocalWorkReader(home: home).load(project: project, now: now)
        XCTAssertEqual(result.prompts.count, 1, String(describing: result))
        XCTAssertEqual(result.prompts.first?.prompt, "Read this 🧭")
        XCTAssertEqual(result.prompts.first?.turn, "good")
        XCTAssertTrue(LocalWorkReader(home: home).load(project: nil, now: now).prompts.isEmpty)
    }
    func testHookInventoryDoesNotExposeCommandsOrClaimExecution() throws {
        let data = Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"python /owned/planisphere_usage.py --token SECRET"},{"command":"echo unrelated"}]}]},"disableAllHooks":true}"#.utf8)
        let rows = try LocalWorkReader.hooks(data: data, host: "Codex", scope: "All projects", path: "/fixture/hooks.json")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].purpose, "Usage collection")
        XCTAssertTrue(rows[0].disabled); XCTAssertNil(rows[0].version)
        XCTAssertFalse(String(describing: rows).contains("SECRET"))
    }
}
