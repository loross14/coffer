import Foundation
import XCTest
import PlanisphereConnection
@testable import PlanisphereApp

final class ReportingHookInstallerTests: XCTestCase {
    private var home: URL!
    private let memoryHook = "/usr/bin/python3 -B /Memory/Host/ClaudeControls/planisphere_shared_feedback.py --settings /Memory/Host/ClaudeControls/settings.json"

    override func setUpWithError() throws {
        home = scratchFolder("reporting-\(UUID().uuidString)").appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

    private func grant(key: String) throws -> [String: [ReportingHookGroup]] {
        try JSONDecoder().decode(ReportingGrant.self, from: SampleHooks.data(SampleHooks.grant(key: key))).hooks
    }
    private func settings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("settings.json"))) as! [String: Any]
    }
    private func commands(_ event: String) throws -> [String] {
        let hooks = try settings()["hooks"] as? [String: Any] ?? [:]
        return (hooks[event] as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testInstallSitsNextToTheMemoryHooksAndKeepsEverythingElse() throws {
        let existing: [String: Any] = ["permissions": ["allow": ["Bash(git status)"]], "model": "opus",
            "hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": memoryHook]]]],
                      "Stop": [["hooks": [["type": "command", "command": memoryHook]]]],
                      "Notification": [["hooks": [["type": "command", "command": "say hi"]]]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: home.appendingPathComponent("settings.json"))
        XCTAssertNil(try ReportingHookInstaller.status(home: home))
        try ReportingHookInstaller.install(try grant(key: "ps_test_first"), home: home)
        let after = try settings()
        XCTAssertEqual(after["model"] as? String, "opus")
        XCTAssertEqual((after["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(git status)"])
        XCTAssertEqual(try commands("UserPromptSubmit").first, memoryHook)
        XCTAssertEqual(try commands("UserPromptSubmit").count, 2)
        XCTAssertEqual(try commands("Stop").count, 2)
        XCTAssertEqual(try commands("Notification"), ["say hi"])
        XCTAssertEqual(try commands("SessionStart").count, 1)
        XCTAssertEqual(try commands("PreToolUse").count, 1)
        let installed = try XCTUnwrap(try ReportingHookInstaller.status(home: home))
        XCTAssertEqual(installed.events, ["PreToolUse", "SessionStart", "Stop", "UserPromptSubmit"])
        XCTAssertEqual(installed.key, "ps_test_first")
        XCTAssertEqual(installed.keyHint, "ps_test_firs…")
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix("settings.json.planisphere-backup-") }
        XCTAssertEqual(backups.count, 1)
        // An existing file keeps its own mode; only a file this installer creates is private (see the fresh-home test).
        let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("settings.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644)
    }

    func testReinstallRotatesTheKeyWithoutDuplicatingHooks() throws {
        try ReportingHookInstaller.install(try grant(key: "ps_test_first"), home: home)
        try ReportingHookInstaller.install(try grant(key: "ps_live_second"), home: home)
        for event in ReportingHooks.events { XCTAssertEqual(try commands(event).count, 1, event) }
        XCTAssertEqual(try ReportingHookInstaller.status(home: home)?.key, "ps_live_second")
        XCTAssertFalse(try commands("Stop")[0].contains("ps_test_first"))
    }

    func testRemoveLeavesOnlyWhatWasThereBefore() throws {
        let existing: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": memoryHook]]]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: home.appendingPathComponent("settings.json"))
        try ReportingHookInstaller.install(try grant(key: "ps_test_first"), home: home)
        XCTAssertEqual(try ReportingHookInstaller.remove(home: home), 4)
        let hooks = try settings()["hooks"] as? [String: Any]
        XCTAssertEqual(hooks?.keys.sorted(), ["UserPromptSubmit"])
        XCTAssertEqual(try commands("UserPromptSubmit"), [memoryHook])
        XCTAssertNil(try ReportingHookInstaller.status(home: home))
        XCTAssertEqual(try ReportingHookInstaller.remove(home: home), 0)
        // A file that only ever held our hooks ends up without a hooks key, not with empty arrays.
        try ReportingHookInstaller.remove(home: home)
        try JSONSerialization.data(withJSONObject: [:] as [String: Any]).write(to: home.appendingPathComponent("settings.json"))
        try ReportingHookInstaller.install(try grant(key: "ps_test_only"), home: home)
        try ReportingHookInstaller.remove(home: home)
        XCTAssertNil(try settings()["hooks"])
    }

    func testFreshHomeAndMalformedOrLinkedFilesAreHandled() throws {
        let fresh = home.deletingLastPathComponent().appendingPathComponent("fresh/.claude")
        try ReportingHookInstaller.install(try grant(key: "ps_test_fresh"), home: fresh)
        XCTAssertEqual(try ReportingHookInstaller.status(home: fresh)?.events.count, 4)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fresh.appendingPathComponent("settings.json").path)[.posixPermissions] as? Int, 0o600)
        try Data("{not json".utf8).write(to: home.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try ReportingHookInstaller.install(try grant(key: "x"), home: home)) { error in
            guard case .malformed = error as? ReportingHookInstaller.InstallError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("settings.json")), Data("{not json".utf8))
        let linked = home.deletingLastPathComponent().appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: home)
        XCTAssertThrowsError(try ReportingHookInstaller.status(home: linked)) { XCTAssertEqual($0 as? ReportingHookInstaller.InstallError, .unsafePath(linked.path)) }
    }
}
