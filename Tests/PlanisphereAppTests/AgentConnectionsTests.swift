import AppKit
import SwiftUI
import XCTest
@testable import PlanisphereApp

@MainActor
final class AgentConnectionsTests: XCTestCase {
    func testEachAgentGetsItsOwnSettingsFlag() {
        let script = URL(fileURLWithPath: "/App/Host/planisphere_memory_setup.py")
        let root = URL(fileURLWithPath: "/Users/you/Memory"), home = URL(fileURLWithPath: "/Users/you/.claude")
        XCTAssertEqual(MemoryHostInstaller.arguments(script: script, root: root, home: home, host: .claudeCode, statusOnly: true),
                       ["-B", script.path, "--memory-root", root.path, "--claude-home", home.path, "--status"])
        XCTAssertEqual(MemoryHostInstaller.arguments(script: script, root: root, home: home, host: .codex, statusOnly: false),
                       ["-B", script.path, "--memory-root", root.path, "--codex-home", home.path])
        XCTAssertEqual(AgentHost.allCases.map(\.name), ["Codex", "Claude Code"])
        // The vault reader's routes are the vaults this app opened: its registry sits beside the memory root.
        let registry = MemoryHostInstaller.registry(memoryRoot: root)
        XCTAssertEqual(registry.path, "/Users/you/registry.json")
        XCTAssertEqual(MemoryHostInstaller.arguments(script: script, root: root, home: home, host: .claudeCode, statusOnly: true, registry: registry),
                       ["-B", script.path, "--memory-root", root.path, "--claude-home", home.path, "--registry", registry.path, "--status"])
    }

    func testCheckSetupReportCarriesTheVaultReader() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T03:03:00Z"))
        let report = AgentHostReport(json: ["status": "installed", "health": "ok", "vault_reader": [
            "vaults": 2, "command": "/Users/pax/Library/Application Support/Planisphere/Memory/Host/Reader/planisphere-reader",
            "link": "/Users/pax/.local/bin/planisphere-reader", "reporting": "off", "problem": NSNull(),
            "routes": [["vault": "Notes", "root": "/Users/pax/Notes", "excluded_paths": ["private"], "read_backend": "planisphere"],
                       ["vault": "Work", "root": "/Users/pax/Work", "excluded_paths": [], "read_backend": "planisphere"]],
            "last_run": ["at": "2026-10-15T03:00:00Z", "action": "query", "exit_code": 0]]])
        let reader = try XCTUnwrap(report.vaultReader)
        XCTAssertEqual(reader.vaults, ["Notes", "Work"])
        XCTAssertEqual(reader.line(now: now), "Vault reader: 2 vaults (Notes, Work) · last read 3 min ago")
        XCTAssertFalse(report.broken)
        let empty = AgentHostReport(json: ["status": "installed", "vault_reader": ["vaults": 0, "routes": [], "problem": "Open a vault in Planisphere, then Check setup."]])
        XCTAssertEqual(empty.vaultReader?.line(now: now), "Vault reader: no vaults opened yet")
        XCTAssertEqual(empty.vaultReader?.problem, "Open a vault in Planisphere, then Check setup.")
        let one = AgentHostReport(json: ["status": "installed", "vault_reader": ["routes": [["vault": "Notes"]],
            "last_run": ["at": "2026-10-15T03:02:00Z", "action": "query", "exit_code": 1]]])
        XCTAssertEqual(one.vaultReader?.line(now: now), "Vault reader: 1 vault (Notes) · last read 1 min ago failed (exit 1)")
        XCTAssertNil(AgentHostReport(json: ["status": "installed"]).vaultReader, "older hosts report no reader")
    }

    func testStatusLinesTellEachAppWhatToDoNext() {
        XCTAssertEqual(MemoryWorkspaceView.agentLine(.codex, status: "not_installed"), "Not connected")
        XCTAssertTrue(MemoryWorkspaceView.agentLine(.claudeCode, status: "installed").contains("/hooks"))
        XCTAssertTrue(MemoryWorkspaceView.agentLine(.codex, status: "installed").contains("new chat"))
        XCTAssertTrue(MemoryWorkspaceView.agentLine(.claudeCode, status: "disabled").contains("turned off in Claude Code"))
        XCTAssertEqual(MemoryWorkspaceView.agentLine(.claudeCode, status: nil), "Status not checked yet")
    }

    func testCheckSetupReportSaysWhatIsWrongAndWhatTheLastRunDid() throws {
        let json: [String: Any] = ["status": "installed", "health": "broken",
            "problem": "The hooks point at a Python that is no longer there (the Planisphere app moved). Connect again to repair them.",
            "app": NSNull(), "last_run": ["at": "2026-10-15T03:00:00Z", "action": "hook", "exit_code": 127,
                "stderr": "sh: /Users/pax/Downloads/Planisphere.app/Contents/Frameworks/Python.framework/Versions/3.13/Python: No such file or directory\n"]]
        let report = AgentHostReport(json: json)
        XCTAssertEqual(report.status, "installed")
        XCTAssertTrue(report.broken)
        XCTAssertNil(report.app)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-15T03:03:00Z"))
        XCTAssertEqual(report.lastRunLine(now: now), "Last hook run 3 min ago: failed (exit 127) — sh: /Users/pax/Downloads/Planisphere.app/Contents/Frameworks/Python.framework/Versions/3.13/Python: No such file or directory")
        let healthy = AgentHostReport(json: ["status": "installed", "health": "ok", "problem": NSNull(), "app": "/Applications/Planisphere.app",
            "last_run": ["at": "2026-10-15T03:02:30Z", "exit_code": 0, "action": "hook", "problem": NSNull()]])
        XCTAssertFalse(healthy.broken)
        XCTAssertEqual(healthy.lastRunLine(now: now), "Last hook run just now: ran (exit 0)")
        let missing = AgentHostReport(json: ["status": "installed", "last_run": ["exit_code": 0, "problem": "app_missing"]])
        XCTAssertEqual(missing.lastRunLine(now: now), "Last hook run: the Planisphere app was not found")
        XCTAssertNil(AgentHostReport(json: ["status": "not_installed"]).lastRunLine(now: now))
        XCTAssertEqual(AgentHostReport(json: [:]).status, "unknown")
    }

    /// Opt-in (PLANISPHERE_SNAPSHOT_DIR=/absolute/folder): renders the agents card in its main states.
    func testRenderAgentConnectionStates() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLANISPHERE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set PLANISPHERE_SNAPSHOT_DIR to render review screenshots")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let broken = AgentHostReport(json: ["status": "installed", "health": "broken",
            "problem": "The hooks point at a Python that is no longer there (the Planisphere app moved). Connect again to repair them.",
            "last_run": ["at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180)), "action": "hook", "exit_code": 127,
                "stderr": "sh: /Users/pax/Downloads/Planisphere.app/Contents/Frameworks/Python.framework/Versions/3.13/Python: No such file or directory\n"]])
        let healthy = AgentHostReport(json: ["status": "installed", "health": "ok", "app": "/Applications/Planisphere.app",
            "last_run": ["at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40)), "action": "hook", "exit_code": 0],
            "vault_reader": ["vaults": 2, "command": "/Users/pax/Library/Application Support/Planisphere/Memory/Host/Reader/planisphere-reader",
                "routes": [["vault": "Notes", "root": "/Users/pax/Notes", "excluded_paths": ["private"]], ["vault": "Work", "root": "/Users/pax/Work", "excluded_paths": []]],
                "last_run": ["at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-200)), "action": "query", "exit_code": 0]]])
        let noVaults = AgentHostReport(json: ["status": "installed", "health": "ok", "app": "/Applications/Planisphere.app",
            "last_run": ["at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40)), "action": "hook", "exit_code": 0],
            "vault_reader": ["vaults": 0, "routes": [], "problem": "Open a vault in Planisphere, then Check setup."]])
        let states: [(String, [AgentHost: String], String?, [AgentHost: AgentHostReport])] = [
            ("fresh", [.codex: "not_installed", .claudeCode: "not_installed"], nil, [:]),
            ("claude-connected", [.codex: "not_installed", .claudeCode: "installed"], AgentHost.claudeCode.installedMessage, [.claudeCode: healthy]),
            ("claude-no-vaults", [.codex: "not_installed", .claudeCode: "installed"], nil, [.claudeCode: noVaults]),
            ("both", [.codex: "installed", .claudeCode: "disabled"], nil, [:]),
            ("claude-broken", [.codex: "not_installed", .claudeCode: "installed"], nil, [.claudeCode: broken]),
        ]
        for (name, agents, message, reports) in states {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let model = MemoryModel(root: URL(fileURLWithPath: "/tmp/planisphere-snapshot/Memory"))
                model.preview(agents: agents, message: message, reports: reports)
                let view = VStack(alignment: .leading, spacing: 12) {
                    AgentConnectionsCard(model: model, line: MemoryWorkspaceView.agentLine, color: MemoryWorkspaceView.agentColor)
                    if let message { Text(message).font(.callout) }
                }.padding(28).frame(width: 760, alignment: .topLeading).background(PSStyle.canvas)
                try render(view, size: NSSize(width: 760, height: name == "claude-broken" ? 400 : name == "fresh" || name == "both" ? 330 : 370), appearance: appearance,
                           to: output.appendingPathComponent("agents-\(name)-\(mode).png"))
            }
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
