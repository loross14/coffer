import Foundation
import XCTest
import PlanisphereConnection
@testable import PlanisphereApp

private final class MemoryCredentials: ConnectionCredentialStoring {
    var value: ConnectionCredential?
    init(_ value: ConnectionCredential?) { self.value = value }
    func read() throws -> ConnectionCredential? { value }
    func save(_ value: ConnectionCredential) throws { self.value = value }
    func remove() throws { value = nil }
}

@MainActor
final class ConsoleConnectionModelTests: XCTestCase {
    private func credential() throws -> ConnectionCredential {
        try JSONDecoder().decode(ConnectionCredential.self, from: Data(#"{"token":"ps_mac_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","connection":{"id":"device","label":"Planisphere on Mac","workspace":{"id":"workspace","name":"My workspace"},"email":null,"expires_at":"2026-11-10T12:00:00Z","permissions":["connection:read","connection:revoke"],"vault_sync_enabled":false}}"#.utf8))
    }

    func testStartupRestoresWorkspaceForAnAccountWithoutEmail() async throws {
        let saved = try credential()
        let body = try JSONEncoder().encode(saved.connection)
        let client = ConsoleClient { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let model = ConsoleConnectionModel(client: client, keychain: MemoryCredentials(saved))
        await model.load()
        XCTAssertEqual(model.title, "My workspace")
        XCTAssertTrue(model.verified)
        XCTAssertFalse(model.needsSignIn)
    }

    func testOfflineStartupKeepsSavedAccountWithoutClaimingVerification() async throws {
        let saved = try credential()
        let store = MemoryCredentials(saved)
        let model = ConsoleConnectionModel(client: ConsoleClient { _ in throw URLError(.notConnectedToInternet) }, keychain: store)
        await model.load()
        XCTAssertEqual(model.title, "My workspace")
        XCTAssertFalse(model.verified)
        XCTAssertFalse(model.needsSignIn)
        XCTAssertEqual(store.value?.token, saved.token)
    }

    func testReconnectRetainsCredentialWhenRevocationFails() async throws {
        let saved = try credential()
        let store = MemoryCredentials(saved)
        var browserOpened = false
        let client = ConsoleClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: request.httpMethod == "DELETE" ? 503 : 401,
                                     httpVersion: nil, headerFields: nil)!)
        }
        let model = ConsoleConnectionModel(client: client, keychain: store, authenticate: { _ in
            browserOpened = true
            throw ConnectionError.unavailable
        })
        await model.load()
        XCTAssertTrue(model.needsSignIn)
        await model.reconnect()
        XCTAssertFalse(browserOpened)
        XCTAssertEqual(store.value?.token, saved.token)
        XCTAssertEqual(model.credential?.token, saved.token)
        XCTAssertFalse(model.busy)
    }

    func testReconnectRevokesOldCredentialBeforeOpeningSignIn() async throws {
        let store = MemoryCredentials(try credential())
        var browserOpened = false
        let client = ConsoleClient { request in
            let status: Int
            let body: Data
            if request.httpMethod == "DELETE" {
                status = 200; body = Data(#"{"disconnected":true}"#.utf8)
            } else if request.url!.path.hasSuffix("/begin") {
                status = 200; body = Data((#"{"authorization_path":"/console#mac-connect/"# + String(repeating: "r", count: 43) + #""}"#).utf8)
            } else { status = 401; body = Data() }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let model = ConsoleConnectionModel(client: client, keychain: store, authenticate: { _ in
            XCTAssertNil(store.value)
            browserOpened = true
            throw ConnectionError.unavailable
        })
        await model.load()
        await model.reconnect()
        XCTAssertTrue(browserOpened)
        XCTAssertNil(model.credential)
        XCTAssertNil(store.value)
        XCTAssertFalse(model.busy)
    }

    func testSignInCallbackOffTheMainThreadReturnsTheURL() async throws {
        let callback = URL(string: "ooo.planisphere.mac://connected?code=c&state=s")!
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            let handler = ConsoleConnectionModel.completion(CallbackHandoff(continuation))
            DispatchQueue.global().async { handler(callback, nil) }
        }
        XCTAssertEqual(received, callback)
    }

    func testHandoffFinishesOnceWhenBothReturnPathsArrive() async throws {
        let callback = URL(string: "ooo.planisphere.mac:/console-connected")!
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            let handoff = CallbackHandoff(continuation)
            handoff.finish(.success(callback))
            ConsoleConnectionModel.completion(handoff)(nil, URLError(.cancelled))
        }
        XCTAssertEqual(received, callback)
    }

    func testReturnLinkOpenedByTheBrowserCompletesSignIn() async throws {
        let store = MemoryCredentials(nil)
        let saved = try credential()
        let state = LockedValue<String?>(nil)
        let client = ConsoleClient { request in
            let path = request.url!.path
            var body = Data()
            if path.hasSuffix("/begin") {
                let sent = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                state.set(sent["state"] as? String)
                body = Data((#"{"authorization_path":"/console#mac-connect/"# + String(repeating: "r", count: 43) + #""}"#).utf8)
            } else if path.hasSuffix("/exchange") {
                body = try JSONEncoder().encode(saved)
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var model: ConsoleConnectionModel!
        let code = String(repeating: "c", count: 43)
        model = ConsoleConnectionModel(client: client, keychain: store, authenticate: { _ in
            // The browser never completes the session; the return link arrives as an opened URL instead.
            let wrong = URL(string: "ooo.planisphere.mac:/console-connected?code=\(code)&state=wrong")!
            XCTAssertFalse(model.receiveCallback(wrong))
            let link = URL(string: "ooo.planisphere.mac:/console-connected?code=\(code)&state=\(state.get()!)")!
            XCTAssertTrue(model.receiveCallback(link))
            // A late session failure must not undo the completed sign-in.
            throw ConnectionError.unavailable
        })
        await model.connect()
        XCTAssertEqual(model.credential?.token, saved.token)
        XCTAssertEqual(store.value?.token, saved.token)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.receiveCallback(URL(string: "ooo.planisphere.mac:/console-connected?code=\(code)&state=\(state.get()!)")!))
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}
