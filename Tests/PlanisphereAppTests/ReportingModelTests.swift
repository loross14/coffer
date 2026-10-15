import Foundation
import XCTest
import PlanisphereConnection
@testable import PlanisphereApp

@MainActor
final class ReportingModelTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = scratchFolder("reporting-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func model(reporting: @escaping @Sendable (URLRequest) throws -> (Int, Data),
                       hooks: [[String: Any]] = []) -> ReportingModel {
        let home = folder.appendingPathComponent(".claude")
        let page = try! JSONSerialization.data(withJSONObject: ["workspace_id": "workspace", "systems": hooks, "truncated": false, "coverage": "test"] as [String: Any])
        let workspace = WorkspaceClient { request in
            (page, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = ReportingClient { request in
            let (status, data) = try reporting(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return ReportingModel(stateURL: folder.appendingPathComponent("Reporting/claude-code.json"), client: client, workspace: workspace, home: { home })
    }
    private func wait(_ model: ReportingModel) async { for _ in 0..<50 where model.busy { try? await Task.sleep(for: .milliseconds(20)) } }

    func testStatesFollowTheLinkThenConnectInstallsHooksAndShowsDelivery() async throws {
        let delivered: [[String: Any]] = [["system_id": "claude-code-primary", "records_24h": 3, "last_recorded_at": "2026-10-14T20:30:00Z", "last_event_type": "agent_response", "observed_connector": NSNull(), "observed_environment": NSNull()]]
        let model = model(reporting: { request in
            if request.httpMethod == "POST" { return (200, SampleHooks.data(SampleHooks.grant(key: "ps_test_minted"))) }
            return (200, SampleHooks.data(["workspace_id": "workspace", "system_id": "claude-code-primary", "keys": [["key_id": "key-1", "label": "Planisphere on Mac · Claude Code hooks", "active": true, "created_at": "2026-10-14T20:00:00Z", "revoked_at": NSNull(), "last_used_at": NSNull()]]]))
        }, hooks: delivered)
        await model.refresh()
        XCTAssertEqual(model.state, .notLinked)
        model.bind(SampleHooks.credential(permissions: ["connection:read", "connection:revoke", "prompts:read", "hooks:read"]), verified: true)
        await Task.yield(); await wait(model)
        XCTAssertEqual(model.state, .needsPermission)
        model.bind(SampleHooks.credential(), verified: false)
        await Task.yield(); await wait(model)
        XCTAssertEqual(model.state, .notLinked)
        model.bind(SampleHooks.credential(), verified: true)
        await Task.yield(); await wait(model)
        XCTAssertEqual(model.state, .notConnected)
        XCTAssertTrue(model.canConnect)
        await model.connect()
        XCTAssertEqual(model.record?.keyID, "key-1")
        XCTAssertEqual(model.record?.workspaceName, "My workspace")
        XCTAssertEqual(try ReportingHookInstaller.status(home: folder.appendingPathComponent(".claude"))?.key, "ps_test_minted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Reporting/claude-code.json").path))
        guard case .connected(let workspace, let last) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(workspace, "My workspace")
        XCTAssertEqual(last, "2026-10-14T20:30:00Z")
        XCTAssertTrue(ReportingModel.line(model.state).hasPrefix("Reporting to My workspace · last delivery "))
        XCTAssertTrue(model.message?.contains("now reports to My workspace") == true)
        // A fresh model on the same Mac picks the record back up.
        let again = self.model(reporting: { _ in (200, SampleHooks.data(["workspace_id": "workspace", "system_id": "claude-code-primary", "keys": []])) })
        XCTAssertEqual(again.record?.keyID, "key-1")
        again.bind(SampleHooks.credential(), verified: true)
        await Task.yield(); await wait(again)
        XCTAssertEqual(again.state, .keyRevoked(workspace: "My workspace"))
        XCTAssertTrue(again.canConnect)
    }

    func testDisconnectRevokesThenRemovesAndTheLinkTakesReportingDownFirst() async throws {
        final class Calls: @unchecked Sendable { var methods: [String] = [] }
        let calls = Calls()
        let model = model(reporting: { request in
            calls.methods.append(request.httpMethod ?? "")
            switch request.httpMethod {
            case "POST": return (200, SampleHooks.data(SampleHooks.grant(key: "ps_test_minted")))
            case "DELETE": return (200, SampleHooks.data(["workspace_id": "workspace", "key": ["key_id": "key-1", "label": "x", "active": false, "created_at": "2026-10-14T20:00:00Z", "revoked_at": "2026-10-14T22:00:00Z", "last_used_at": NSNull()]]))
            default: return (200, SampleHooks.data(["workspace_id": "workspace", "system_id": "claude-code-primary", "keys": [["key_id": "key-1", "label": "x", "active": true, "created_at": "2026-10-14T20:00:00Z", "revoked_at": NSNull(), "last_used_at": NSNull()]]]))
            }
        })
        model.bind(SampleHooks.credential(), verified: true)
        await Task.yield(); await wait(model)
        await model.connect()
        XCTAssertTrue(model.isConnected)
        await model.disconnect()
        XCTAssertTrue(calls.methods.contains("DELETE"))
        XCTAssertNil(try ReportingHookInstaller.status(home: folder.appendingPathComponent(".claude")))
        XCTAssertNil(model.record)
        XCTAssertEqual(model.state, .notConnected)
        XCTAssertTrue(model.message?.hasPrefix("Claude Code no longer reports from this Mac.") == true)
        // The console connection's own Disconnect calls this before revoking the device token.
        await model.connect()
        calls.methods = []
        await model.linkWillDisconnect(SampleHooks.credential())
        XCTAssertEqual(calls.methods.filter { $0 == "DELETE" }.count, 1)
        XCTAssertNil(model.record)
    }

    func testAnUnreachableConsoleLeavesTheHooksAloneAndSaysSo() async throws {
        let model = model(reporting: { _ in throw URLError(.notConnectedToInternet) })
        model.bind(SampleHooks.credential(), verified: true)
        await Task.yield(); await wait(model)
        XCTAssertEqual(model.state, .notConnected)
        await model.connect()
        XCTAssertNil(try ReportingHookInstaller.status(home: folder.appendingPathComponent(".claude")))
        XCTAssertEqual(model.message, ReportingError.unavailable.errorDescription)
        XCTAssertEqual(ReportingModel.line(.notLinked), "Connect this Mac to the console and this step also reports Claude Code activity there.")
        // Hooks pasted from the console on a Mac that was never linked are not an error.
        try ReportingHookInstaller.install(try JSONDecoder().decode(ReportingGrant.self, from: SampleHooks.data(SampleHooks.grant(key: "ps_live_pasted"))).hooks, home: folder.appendingPathComponent(".claude"))
        model.bind(nil, verified: false)
        await Task.yield(); await wait(model)
        XCTAssertEqual(model.state, .installedElsewhere)
        XCTAssertFalse(model.linked)
        XCTAssertEqual(ReportingModel.line(.keyRevoked(workspace: "Acme")), "Reporting to Acme stopped: its key was revoked in the console. Connect reporting again for a new key.")
    }
}
