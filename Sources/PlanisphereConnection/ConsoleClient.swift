import CryptoKit
import Foundation
import Security

public enum ConnectionError: Error, LocalizedError, Equatable {
    case invalidResponse, unavailable, signInAgain, keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The console returned an unexpected response. Start a new connection."
        case .unavailable: "The console could not be reached. Check your connection and try again."
        case .signInAgain: "This connection has expired or was disconnected. Connect again."
        case .keychain: "The connection could not be saved in Keychain. Unlock your keychain and try again."
        }
    }
}

public struct ConnectionIdentity: Codable, Sendable, Equatable {
    public struct Workspace: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
    }
    public let id: String
    public let label: String
    public let workspace: Workspace
    public let email: String?
    public let expires_at: String
    public let permissions: [String]
    public let vault_sync_enabled: Bool
}

public struct ConnectionCredential: Codable, Sendable {
    public let token: String
    public var connection: ConnectionIdentity
}

public struct ConnectionAttempt: Sendable {
    public let verifier: String
    public let state: String
    public var challenge: String { Self.base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init() throws {
        verifier = try Self.random()
        state = try Self.random()
    }
    public init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ConnectionError.unavailable }
        return base64(Data(bytes))
    }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public func code(from callback: URL) throws -> String {
        guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              url.scheme == "ooo.planisphere.mac", url.host == nil, url.path == "/console-connected",
              url.fragment == nil, url.user == nil, url.password == nil else { throw ConnectionError.invalidResponse }
        let items = url.queryItems ?? []
        let states = items.filter { $0.name == "state" }, codes = items.filter { $0.name == "code" }
        guard items.count == 2, states.count == 1, states[0].value == state,
              codes.count == 1, let code = codes[0].value,
              code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw ConnectionError.invalidResponse }
        return code
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ConsoleClient: Sendable {
    public static let production = URL(string: "https://api.planisphere.ooo")!
    public let origin: URL
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init() {
        origin = Self.production
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        send = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
            return (data, http)
        }
    }
    // Explicit transport injection is for tests; app builds always use the fixed HTTPS origin above.
    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        origin = Self.production
        self.send = send
    }

    private func request(_ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil, permissions: [String]? = nil) async throws -> Data {
        var request = URLRequest(url: origin.appendingPathComponent("mac/connections" + path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            var object: [String: Any] = body
            if let permissions { object["permissions"] = permissions }
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, HTTPURLResponse)
        do { result = try await send(request) } catch { throw ConnectionError.unavailable }
        let (data, response) = result
        guard response.url == request.url else { throw ConnectionError.invalidResponse }
        if response.statusCode == 401 { throw ConnectionError.signInAgain }
        guard (200..<300).contains(response.statusCode), data.count < 65_536 else {
            throw (response.statusCode >= 500 ? ConnectionError.unavailable : ConnectionError.invalidResponse)
        }
        return data
    }

    /// The read scopes plus activity:record, which lets Connect Claude Code also install the console's reporting hooks.
    public static let permissions = ["prompts:read", "hooks:read", ReportingHooks.scope]
    /// What a console from before activity:record accepts; it rejects the full list outright (422).
    public static let legacyPermissions = ["prompts:read", "hooks:read"]

    public func begin(_ attempt: ConnectionAttempt) async throws -> URL {
        do { return try await begin(attempt, permissions: Self.permissions) }
        catch ConnectionError.invalidResponse { return try await begin(attempt, permissions: Self.legacyPermissions) }
    }
    public func begin(_ attempt: ConnectionAttempt, permissions: [String]) async throws -> URL {
        struct Started: Decodable { let authorization_path: String }
        let data = try await request("/begin", method: "POST", body: ["challenge": attempt.challenge, "state": attempt.state, "label": "Planisphere on Mac"], permissions: permissions)
        let result = try JSONDecoder().decode(Started.self, from: data)
        guard result.authorization_path.range(of: "^/console#mac-connect/[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let url = URL(string: result.authorization_path, relativeTo: origin)?.absoluteURL else { throw ConnectionError.invalidResponse }
        return url
    }

    public func exchange(_ code: String, attempt: ConnectionAttempt) async throws -> ConnectionCredential {
        let data = try await request("/exchange", method: "POST", body: ["code": code, "verifier": attempt.verifier])
        let result = try JSONDecoder().decode(ConnectionCredential.self, from: data)
        guard result.token.range(of: "^ps_mac_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw ConnectionError.invalidResponse }
        return result
    }
    public func status(_ token: String) async throws -> ConnectionIdentity {
        try JSONDecoder().decode(ConnectionIdentity.self, from: await request("/device", token: token))
    }
    public func disconnect(_ token: String) async throws {
        struct Disconnected: Decodable { let disconnected: Bool }
        let data = try await request("/device", method: "DELETE", token: token)
        guard try JSONDecoder().decode(Disconnected.self, from: data).disconnected else { throw ConnectionError.invalidResponse }
    }
}
