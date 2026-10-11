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
}
