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
    }

    func testStatusLinesTellEachAppWhatToDoNext() {
        XCTAssertEqual(MemoryWorkspaceView.agentLine(.codex, status: "not_installed"), "Not connected")
        XCTAssertTrue(MemoryWorkspaceView.agentLine(.claudeCode, status: "installed").contains("/hooks"))
        XCTAssertTrue(MemoryWorkspaceView.agentLine(.codex, status: "installed").contains("new chat"))
        XCTAssertTrue(MemoryWorkspaceView.agentLine(.claudeCode, status: "disabled").contains("turned off in Claude Code"))
        XCTAssertEqual(MemoryWorkspaceView.agentLine(.claudeCode, status: nil), "Status not checked yet")
    }

    /// Opt-in (PLANISPHERE_SNAPSHOT_DIR=/absolute/folder): renders the agents card in its main states.
    func testRenderAgentConnectionStates() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLANISPHERE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set PLANISPHERE_SNAPSHOT_DIR to render review screenshots")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let states: [(String, [AgentHost: String], String?)] = [
            ("fresh", [.codex: "not_installed", .claudeCode: "not_installed"], nil),
            ("claude-connected", [.codex: "not_installed", .claudeCode: "installed"], AgentHost.claudeCode.installedMessage),
            ("both", [.codex: "installed", .claudeCode: "disabled"], nil),
        ]
        for (name, agents, message) in states {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let model = MemoryModel(root: URL(fileURLWithPath: "/tmp/planisphere-snapshot/Memory"))
                model.preview(agents: agents, message: message)
                let view = VStack(alignment: .leading, spacing: 12) {
                    AgentConnectionsCard(model: model, line: MemoryWorkspaceView.agentLine, color: { status in
                        status == "installed" ? Color(nsColor: .systemGreen)
                            : status == "disabled" ? Color(nsColor: .systemOrange) : Color.secondary.opacity(0.5) })
                    if let message { Text(message).font(.callout) }
                }.padding(28).frame(width: 760, alignment: .topLeading).background(PSStyle.canvas)
                try render(view, size: NSSize(width: 760, height: 330), appearance: appearance,
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
