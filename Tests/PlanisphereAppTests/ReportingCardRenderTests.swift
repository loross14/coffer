import AppKit
import SwiftUI
import XCTest
@testable import PlanisphereApp

@MainActor
final class ReportingCardRenderTests: XCTestCase {
    func testReportingLinesPerAgent() {
        let model = ReportingModel(stateURL: URL(fileURLWithPath: "/tmp/planisphere-snapshot/none.json"))
        model.preview(.notLinked)
        XCTAssertNil(AgentConnectionsCard.reportingLine(.codex, model))
        XCTAssertEqual(AgentConnectionsCard.reportingLine(.claudeCode, model), ReportingModel.line(.notLinked))
        model.preview(.connected(workspace: "Acme", lastDelivery: nil))
        XCTAssertEqual(AgentConnectionsCard.reportingLine(.claudeCode, model), "Reporting to Acme · no delivery yet")
        XCTAssertEqual(AgentConnectionsCard.reportingLine(.codex, model), "Reporting for Codex is set up per project from Connections in the console.")
        XCTAssertTrue(model.linked)
        XCTAssertNil(AgentConnectionsCard.reportingLine(.claudeCode, nil))
    }

    /// Opt-in (PLANISPHERE_SNAPSHOT_DIR=/absolute/folder): renders the Agents card with reporting in its main states.
    func testRenderAgentsCardWithReporting() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLANISPHERE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set PLANISPHERE_SNAPSHOT_DIR to render review screenshots")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let states: [(String, [AgentHost: String], ReportingModel.State, String?)] = [
            ("not-linked", [.codex: "not_installed", .claudeCode: "not_installed"], .notLinked, nil),
            ("console-hooks-unlinked", [.codex: "not_installed", .claudeCode: "installed"], .installedElsewhere, nil),
            ("linked-fresh", [.codex: "not_installed", .claudeCode: "not_installed"], .notConnected, nil),
            ("memory-only", [.codex: "installed", .claudeCode: "installed"], .notConnected, nil),
            ("needs-permission", [.codex: "not_installed", .claudeCode: "installed"], .needsPermission, nil),
            ("reporting", [.codex: "installed", .claudeCode: "installed"], .connected(workspace: "Pax’s workspace", lastDelivery: "2026-10-14T21:12:00Z"),
             "Claude Code now reports to Pax’s workspace. Its hooks are in /Users/pax/.claude/settings.json; the workspace key is listed under Keys in the console."),
            ("key-revoked", [.codex: "not_installed", .claudeCode: "installed"], .keyRevoked(workspace: "Pax’s workspace"), nil),
        ]
        for (name, agents, reporting, message) in states {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let memory = MemoryModel(root: URL(fileURLWithPath: "/tmp/planisphere-snapshot/Memory"))
                memory.preview(agents: agents)
                let report = ReportingModel(stateURL: URL(fileURLWithPath: "/tmp/planisphere-snapshot/none.json"))
                report.preview(reporting, message: message)
                let view = AgentConnectionsCard(model: memory, reporting: report, line: MemoryWorkspaceView.agentLine, color: { status in
                    status == "installed" ? Color(nsColor: .systemGreen) : status == "disabled" ? Color(nsColor: .systemOrange) : Color.secondary.opacity(0.5) })
                    .padding(28).frame(width: 760, alignment: .topLeading).background(PSStyle.canvas)
                try render(view, size: NSSize(width: 760, height: 360), appearance: appearance, to: output.appendingPathComponent("agents-reporting-\(name)-\(mode).png"))
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
