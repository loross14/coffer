import Foundation
import XCTest
import PlanisphereConnection
@testable import PlanisphereApp

private actor DeferredWorkspace {
    var pending: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    var requested = false
    var waiting: CheckedContinuation<Void, Never>?
    var request: URLRequest?
    func send(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        self.request = request
        return await withCheckedContinuation { continuation in
            pending = continuation; requested = true; waiting?.resume(); waiting = nil
        }
    }
    func started() async { if !requested { await withCheckedContinuation { waiting = $0 } } }
    func finish() {
        let data = Data(#"{"workspace_id":"a","prompts":[],"next_cursor":"private-cursor","coverage":"reported"}"#.utf8)
        pending?.resume(returning: (data, HTTPURLResponse(url: request!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        pending = nil
    }
}
@MainActor final class WorkspaceActivityModelTests: XCTestCase {
    private func credential(_ workspace: String) throws -> ConnectionCredential {
        let value: [String: Any] = ["token": "token-" + workspace, "connection": ["id": workspace, "label": "Mac", "workspace": ["id": workspace, "name": workspace], "expires_at": "2026-11-01T00:00:00Z", "permissions": ["prompts:read", "hooks:read"], "vault_sync_enabled": false]]
        return try JSONDecoder().decode(ConnectionCredential.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testDelayedOldAccountResponseCannotRepopulateEvenAfterSwitchingBack() async throws {
        let gate = DeferredWorkspace()
        let model = WorkspaceActivityModel(client: WorkspaceClient { request in await gate.send(request) })
        model.bind(try credential("a"), verified: true)
        let request = Task { await model.loadPrompts() }
        await gate.started()
        model.bind(try credential("b"), verified: true)
        model.bind(try credential("a"), verified: true)
        await gate.finish(); await request.value
        XCTAssertNil(model.nextCursor); XCTAssertTrue(model.prompts.isEmpty); XCTAssertFalse(model.busy)
    }
    func testUnverifiedOrDisconnectedAccountClearsCloudState() async throws {
        let client = WorkspaceClient { request in
            (Data(#"{"workspace_id":"a","prompts":[],"next_cursor":"private-cursor","coverage":"reported"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let model = WorkspaceActivityModel(client: client)
        let saved = try credential("a")
        model.bind(saved, verified: true); await model.loadPrompts()
        XCTAssertEqual(model.nextCursor, "private-cursor")
        model.bind(saved, verified: false)
        XCTAssertNil(model.nextCursor); XCTAssertTrue(model.hooks.isEmpty); XCTAssertNil(model.detail)
    }

    func testDeniedDetailClearsPreviouslyLoadedWorkspaceState() async throws {
        let client = WorkspaceClient { request in
            let list = request.url!.path == "/mac/workspace/prompts"
            return (Data(#"{"workspace_id":"a","prompts":[],"next_cursor":"private-cursor","coverage":"reported"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: list ? 200 : 403, httpVersion: nil, headerFields: nil)!)
        }
        let model = WorkspaceActivityModel(client: client)
        model.bind(try credential("a"), verified: true)
        await model.loadPrompts()
        XCTAssertEqual(model.nextCursor, "private-cursor")
        await model.select("prompt-a")
        XCTAssertNil(model.nextCursor)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.detailBusy)
        await model.loadPrompts()
        XCTAssertNil(model.detailMessage)
    }
}
