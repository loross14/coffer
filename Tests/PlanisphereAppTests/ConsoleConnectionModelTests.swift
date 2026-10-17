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
        let model = ConsoleConnectionModel(client: client, keychain: store, findBrowsers: { Self.browsers }, open: { _, _ in
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
        let model = ConsoleConnectionModel(client: signInClient(saved: nil, revoke: true), keychain: store,
                                           findBrowsers: { Self.browsers }, open: { _, _ in
            XCTAssertNil(store.value)
            browserOpened = true
            throw ConnectionSignInError.browserUnavailable("Arc")
        })
        await model.load()
        await model.reconnect()
        XCTAssertTrue(browserOpened)
        XCTAssertNil(model.credential)
        XCTAssertNil(store.value)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.message, ConnectionSignInError.browserUnavailable("Arc").localizedDescription)
    }

    func testReturnLinkFromTheChosenBrowserCompletesSignIn() async throws {
        let store = MemoryCredentials(nil)
        let saved = try credential()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("com.apple.Safari", forKey: ConsoleConnectionModel.browserPreferenceKey)
        var model: ConsoleConnectionModel!
        model = ConsoleConnectionModel(client: signInClient(saved: saved), keychain: store, defaults: defaults,
                                       findBrowsers: { Self.browsers }, open: { url, browser in
            XCTAssertEqual(url.absoluteString, "https://api.planisphere.ooo/console#mac-connect/" + String(repeating: "r", count: 43))
            XCTAssertEqual(browser?.id, "com.apple.Safari")
            XCTAssertTrue(model.canCancelSignIn)
            XCTAssertFalse(model.receiveCallback(self.returnLink(state: "wrong")))
            XCTAssertTrue(model.receiveCallback(self.returnLink(state: self.state.get()!)))
        })
        await model.connect()
        XCTAssertEqual(model.credential?.token, saved.token)
        XCTAssertEqual(store.value?.token, saved.token)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.canCancelSignIn)
        XCTAssertFalse(model.receiveCallback(returnLink(state: state.get()!)))
    }

    func testCancelStopsWaitingForTheBrowser() async throws {
        var model: ConsoleConnectionModel!
        model = ConsoleConnectionModel(client: signInClient(saved: nil), keychain: MemoryCredentials(nil),
                                       findBrowsers: { Self.browsers }, open: { _, _ in model.cancel() })
        await model.connect()
        XCTAssertNil(model.credential)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.canCancelSignIn)
        XCTAssertEqual(model.message, ConnectionSignInError.cancelled.localizedDescription)
        XCTAssertFalse(model.receiveCallback(returnLink(state: state.get()!)))
    }

    func testSignInExpiresWhenTheBrowserNeverReturns() async throws {
        let model = ConsoleConnectionModel(client: signInClient(saved: nil), keychain: MemoryCredentials(nil),
                                           findBrowsers: { Self.browsers }, open: { _, _ in }, signInTimeout: .milliseconds(50))
        await model.connect()
        XCTAssertNil(model.credential)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.message, ConnectionSignInError.expired.localizedDescription)
    }

    func testBrowserChoiceIsRememberedAndFallsBackToTheDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let first = ConsoleConnectionModel(defaults: defaults, findBrowsers: { Self.browsers })
        first.refreshBrowsers()
        XCTAssertEqual(first.browser?.id, "company.thebrowser.Browser")
        first.chosenBrowserID = "com.apple.Safari"
        let second = ConsoleConnectionModel(defaults: defaults, findBrowsers: { Self.browsers })
        second.refreshBrowsers()
        XCTAssertEqual(second.browser?.id, "com.apple.Safari")
        let removed = ConsoleConnectionModel(defaults: defaults, findBrowsers: { Array(Self.browsers.prefix(1)) })
        removed.refreshBrowsers()
        XCTAssertEqual(removed.browser?.id, "company.thebrowser.Browser")
    }

    func testHandoffFinishesOnceFromAnyThread() async throws {
        let link = URL(string: "ooo.planisphere.mac:/console-connected")!
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            let handoff = CallbackHandoff(continuation)
            DispatchQueue.global().async {
                handoff.finish(.success(link))
                handoff.finish(.failure(ConnectionSignInError.expired))
            }
        }
        XCTAssertEqual(received, link)
    }

    private static let browsers = [
        SignInBrowser(id: "company.thebrowser.Browser", name: "Arc", url: URL(fileURLWithPath: "/Applications/Arc.app"), isDefault: true),
        SignInBrowser(id: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"), isDefault: false),
    ]
    private let state = LockedValue<String?>(nil)

    private func returnLink(state: String) -> URL {
        URL(string: "ooo.planisphere.mac:/console-connected?code=\(String(repeating: "c", count: 43))&state=\(state)")!
    }

    private func signInClient(saved: ConnectionCredential?, revoke: Bool = false) -> ConsoleClient {
        let state = state
        return ConsoleClient { request in
            let path = request.url!.path
            if revoke, request.httpMethod == "DELETE" {
                return (Data(#"{"disconnected":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/begin") {
                let sent = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                state.set(sent["state"] as? String)
                let body = Data((#"{"authorization_path":"/console#mac-connect/"# + String(repeating: "r", count: 43) + #""}"#).utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/exchange"), let saved {
                return (try JSONEncoder().encode(saved), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}
