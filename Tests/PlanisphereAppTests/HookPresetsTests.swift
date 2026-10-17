import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import PlanisphereApp

@MainActor
final class HookPresetsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_500_000)

    func testArgumentsNameTheHostHomeAndThePreset() {
        let script = URL(fileURLWithPath: "/App/Host/planisphere_hook_presets.py")
        let root = URL(fileURLWithPath: "/Users/you/Memory"), home = URL(fileURLWithPath: "/Users/you/.claude")
        let runtime = URL(fileURLWithPath: "/Users/you/Models/runtime.json")
        XCTAssertEqual(HookPresetsService.arguments(script: script, root: root, home: home, host: .claudeCode, runtime: runtime, install: nil),
                       ["-B", script.path, "--memory-root", root.path, "--claude-home", home.path, "--runtime", runtime.path])
        XCTAssertEqual(HookPresetsService.arguments(script: script, root: root, home: home, host: .codex, runtime: runtime, install: .responseCheck).suffix(2),
                       ["--install", "response-check"])
        XCTAssertEqual(HookPreset.allCases.map(\.name), ["Context provisioning", "Local support", "Response check"])
    }

    func testReportDecodesWhatTheHostToolsPrint() throws {
        let data = Data("""
        {"host":"claude-code","presets":[
          {"id":"context","installed":"installed","runs":3,"last_run":1760499000.5,"last_error":null},
          {"id":"support","installed":"not_installed","mode":"observe","model":"not_running","model_id":"","runs":0,"last_run":null,"last_result":null,"last_error":null},
          {"id":"response-check","installed":"installed","model_review":false,"runs":1,"last_run":1760499100,"last_error":{"at":1760499100,"message":"support paused"}}]}
        """.utf8)
        let report = try JSONDecoder().decode(HookPresetReport.self, from: data)
        XCTAssertEqual(report.presets.map(\.id), ["context", "support", "response-check"])
        XCTAssertEqual(report.presets[1].model, "not_running")
        XCTAssertEqual(report.presets[2].last_error?.message, "support paused")
    }

    func testStatusLinesNeverClaimActivityWithoutARecordedRun() {
        let installedContext = HookPresetStatus(id: "context", installed: "installed")
        XCTAssertEqual(HookPresetsModel.line(nil, preset: .context, host: .claudeCode, context: nil, now: now), "Status not checked yet")
        XCTAssertEqual(HookPresetsModel.line(installedContext, preset: .context, host: .claudeCode, context: installedContext, now: now),
                       "Installed · no runs recorded yet · activation unknown · delivery unverified")
        let ran = HookPresetStatus(id: "context", installed: "installed", runs: 12, last_run: now.timeIntervalSince1970 - 180)
        XCTAssertEqual(HookPresetsModel.line(ran, preset: .context, host: .claudeCode, context: ran, now: now),
                       "Installed · 12 turns · last ran 3 min. ago · activation unknown · delivery unverified")
        let failed = HookPresetStatus(id: "context", installed: "installed", runs: 1, last_run: now.timeIntervalSince1970 - 3600,
                                      last_error: .init(at: now.timeIntervalSince1970 - 60, message: "RuntimeError: boom"))
        XCTAssertTrue(HookPresetsModel.line(failed, preset: .context, host: .codex, context: failed, now: now).hasSuffix("Last error 1 min. ago: RuntimeError: boom"))
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "context", installed: "disabled"), preset: .context, host: .codex, context: nil, now: now),
                       "Installed, but turned off in Codex · no runs recorded yet")
    }

    func testSupportAndResponseCheckLinesSayWhatToInstallFirst() {
        let none = HookPresetStatus(id: "context", installed: "not_installed")
        let installed = HookPresetStatus(id: "context", installed: "installed")
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "support", installed: "not_installed", model: "not_installed"), preset: .support, host: .claudeCode, context: installed, now: now),
                       "Install the Planisphere model in Local first")
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "support", installed: "not_installed", model: "not_running"), preset: .support, host: .claudeCode, context: installed, now: now),
                       "Start the Planisphere model in Local first")
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "support", installed: "not_installed", model: "ready"), preset: .support, host: .claudeCode, context: none, now: now),
                       "Install Context provisioning first")
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "support", installed: "installed", mode: "observe", model: "ready"), preset: .support, host: .claudeCode, context: installed, now: now),
                       "Installed · observing, delivery unchanged · no runs recorded yet")
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "support", installed: "disabled", model: "ready"), preset: .support, host: .claudeCode, context: installed, now: now),
                       "Installed, but support is paused · no runs recorded yet")
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "response-check", installed: "not_installed"), preset: .responseCheck, host: .codex, context: none, now: now),
                       "Install Context provisioning first")
        XCTAssertEqual(HookPresetsModel.line(HookPresetStatus(id: "response-check", installed: "installed", runs: 2, last_run: now.timeIntervalSince1970 - 30, model_review: true), preset: .responseCheck, host: .codex, context: installed, now: now),
                       "Installed · local model review permitted · 2 checks · last ran 30 sec. ago")
        XCTAssertTrue(HookPresetsModel.line(HookPresetStatus(id: "response-check", installed: "installed", model_review: false), preset: .responseCheck, host: .codex, context: installed, now: now)
            .contains("bounded checks"))
    }

    /// The real host tools against a disposable Memory root and agent home; nothing in ~/.claude or ~/.codex is read or written.
    func testHostToolsInstallIntoATemporaryHome() async throws {
        // The host tools refuse symlinked parents and Foundation shortens /private/var to /var, so use /private/tmp.
        let base = URL(fileURLWithPath: "/private/tmp/planisphere-hook-presets-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Memory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let helper = base.appendingPathComponent("planisphere-memory")
        let body = Data("#!/bin/sh\nexit 0\n".utf8)
        try body.write(to: helper)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let connection = ["version": 1, "helper_path": helper.path, "profile": "test", "helper_sha256": digest] as [String: Any]
        try JSONSerialization.data(withJSONObject: connection).write(to: root.appendingPathComponent("connection.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("connection.json").path)
        let home = base.appendingPathComponent(".claude", isDirectory: true)
        let runtime = base.appendingPathComponent("Models/absent.json")
        let service = HookPresetsService()
        do {
            let fresh = try await service.run(root: root, home: home, host: .claudeCode, runtime: runtime)
            XCTAssertEqual(fresh.presets.map(\.installed), ["not_installed", "not_installed", "not_installed"])
            XCTAssertEqual(fresh.presets[1].model, "not_installed")
            let installed = try await service.run(root: root, home: home, host: .claudeCode, runtime: runtime, install: .context)
            XCTAssertEqual(installed.presets[0].installed, "installed")
            XCTAssertEqual(installed.presets[0].runs, 0)
            let hooks = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("settings.json"))) as? [String: Any]
            let events = (hooks?["hooks"] as? [String: Any]).map { Array($0.keys) } ?? []
            XCTAssertEqual(Set(events), ["SessionStart", "UserPromptSubmit", "Stop"])
            let checked = try await service.run(root: root, home: home, host: .claudeCode, runtime: runtime, install: .responseCheck)
            XCTAssertEqual(checked.presets[2].installed, "installed")
            XCTAssertEqual(checked.presets[2].model_review, false)
        } catch MemoryHostError.unavailable {
            throw XCTSkip("Host tools are not staged in .build/memory-host for this checkout")
        }
    }

    /// Opt-in (PLANISPHERE_SNAPSHOT_DIR=/absolute/folder): renders the presets card in its main states.
    func testRenderHookPresetStates() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLANISPHERE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set PLANISPHERE_SNAPSHOT_DIR to render review screenshots")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let t = Date().timeIntervalSince1970
        let fresh: [HookPresetStatus] = [.init(id: "context", installed: "not_installed"),
                                         .init(id: "support", installed: "not_installed", model: "not_installed"),
                                         .init(id: "response-check", installed: "not_installed")]
        let claudeRunning: [HookPresetStatus] = [.init(id: "context", installed: "installed", runs: 14, last_run: t - 240),
                                                 .init(id: "support", installed: "installed", runs: 6, last_run: t - 240, mode: "observe", model: "ready"),
                                                 .init(id: "response-check", installed: "installed", runs: 13, last_run: t - 250, model_review: true)]
        let codexPartial: [HookPresetStatus] = [.init(id: "context", installed: "installed", runs: 2, last_run: t - 7200,
                                                      last_error: .init(at: t - 3600, message: "ValueError: Claude Code supplied no prompt_id")),
                                                .init(id: "support", installed: "not_installed", model: "ready"),
                                                .init(id: "response-check", installed: "installed", model_review: false)]
        let states: [(String, [AgentHost: [HookPresetStatus]], String?)] = [
            ("fresh", [.codex: fresh, .claudeCode: fresh], nil),
            ("mixed", [.codex: codexPartial, .claudeCode: claudeRunning], HookPresetsModel.installedMessage(.support, .claudeCode)),
        ]
        for (name, reports, message) in states {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let model = HookPresetsModel(root: URL(fileURLWithPath: "/tmp/planisphere-snapshot/Memory"),
                                             runtime: URL(fileURLWithPath: "/tmp/planisphere-snapshot/Models/runtime.json"))
                model.preview(reports, message: message)
                let view = HookPresetsCard(model: model, openLocal: {}).padding(24).frame(width: 900)
                    .background(PSStyle.canvas)
                try render(view, width: 900, appearance: appearance, to: output.appendingPathComponent("hooks-presets-\(name)-\(mode).png"))
            }
        }
    }

    private func render<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(size.height, 200)))
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
