import Foundation

/// The console's Claude Code reporting hooks, as a linked Mac receives them (mac_reporting routes).
public enum ReportingHooks {
    public static let scope = "activity:record"
    public static let systemID = "claude-code-primary"
    public static let recordURL = "https://api.planisphere.ooo/v1/record"
    public static let events = ["SessionStart", "PreToolUse", "UserPromptSubmit", "Stop"]
    public static let settingsFile = "~/.claude/settings.json"

    /// A hook command the console's generator produced, whichever workspace key it carries.
    public static func isReportingCommand(_ command: String) -> Bool {
        (command.contains("system_id:\"\(systemID)\"") && command.contains(recordURL))
            || (command.hasPrefix("INPUT=$(cat); mkdir -p /tmp/planisphere; ") && command.contains("/tmp/planisphere/model-"))
    }
    /// The workspace key a reporting command posts with, when it has one.
    public static func key(in command: String) -> String? {
        guard let range = command.range(of: #"X-Planisphere-Key: (ps_[A-Za-z0-9_-]+)""#, options: .regularExpression) else { return nil }
        return String(command[range].dropFirst("X-Planisphere-Key: ".count).dropLast())
    }
}

public enum ReportingError: Error, LocalizedError, Equatable {
    case permissionRequired, keyAuthorityRequired, unavailable, invalidResponse, signInAgain, notOffered
    public var errorDescription: String? {
        switch self {
        case .permissionRequired: "Reconnect this Mac to the console and approve activity recording."
        case .keyAuthorityRequired: "This account cannot manage workspace keys. A workspace owner or admin can connect reporting."
        case .unavailable: "The console could not be reached. Reporting was not changed."
        case .invalidResponse: "The console returned hooks this app could not read safely. Update the app and try again."
        case .signInAgain: "This connection has expired or was disconnected. Connect again."
        case .notOffered: "This console does not offer Mac reporting yet. Until it does, install the hooks from Connections in the console."
        }
    }
}

public struct ReportingKey: Codable, Sendable, Equatable {
    public let key_id: String
    public let label: String
    public let active: Bool
    public let created_at: String
    public let revoked_at: String?
    public let last_used_at: String?
}
public struct ReportingHook: Codable, Sendable, Equatable {
    public let type: String
    public let command: String
}
public struct ReportingHookGroup: Codable, Sendable, Equatable {
    public let matcher: String?
    public let hooks: [ReportingHook]
}
public struct ReportingGrant: Codable, Sendable, Equatable {
    public let workspace_id: String
    public let system_id: String
    public let key: ReportingKey
    public let settings_file: String
    public let hooks: [String: [ReportingHookGroup]]
}
public struct ReportingKeys: Codable, Sendable, Equatable {
    public let workspace_id: String
    public let system_id: String
    public let keys: [ReportingKey]
}

private final class ReportingNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Mints, checks and revokes the workspace key behind this Mac's Claude Code reporting hooks.
public struct ReportingClient: Sendable {
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: ReportingNoRedirects(), delegateQueue: nil)
        send = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReportingError.invalidResponse }
            return (data, http)
        }
    }
    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) { self.send = send }

    private func request(_ path: String, method: String, credential: ConnectionCredential, body: [String: String]? = nil) async throws -> Data {
        guard credential.connection.permissions.contains(ReportingHooks.scope) else { throw ReportingError.permissionRequired }
        var request = URLRequest(url: ConsoleClient.production.appendingPathComponent("mac/workspace/reporting/claude-code" + path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let result: (Data, HTTPURLResponse)
        do { result = try await send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ReportingError.unavailable }
        let (data, response) = result
        guard response.url == request.url else { throw ReportingError.invalidResponse }
        switch response.statusCode {
        case 401: throw ReportingError.signInAgain
        case 403:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String ?? ""
            throw detail.contains("workspace keys") ? ReportingError.keyAuthorityRequired : ReportingError.permissionRequired
        case 404: throw ReportingError.notOffered
        case 429, 500...: throw ReportingError.unavailable
        case 200: break
        default: throw ReportingError.invalidResponse
        }
        guard data.count <= 1_048_576 else { throw ReportingError.invalidResponse }
        return data
    }
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ReportingError.invalidResponse }
    }

    public func status(_ credential: ConnectionCredential) async throws -> ReportingKeys {
        let keys: ReportingKeys = try decode(await request("", method: "GET", credential: credential))
        guard keys.workspace_id == credential.connection.workspace.id, keys.system_id == ReportingHooks.systemID else { throw ReportingError.invalidResponse }
        return keys
    }

    /// Mints a workspace key and returns the console's hooks carrying it. `replacing` rotates the key this Mac made before.
    public func issue(_ credential: ConnectionCredential, replacing keyID: String? = nil) async throws -> ReportingGrant {
        let body = keyID.map { ["replaces_key_id": $0] } ?? [:]
        let grant: ReportingGrant = try decode(await request("", method: "POST", credential: credential, body: body))
        guard grant.workspace_id == credential.connection.workspace.id, grant.system_id == ReportingHooks.systemID,
              grant.key.active, grant.settings_file == ReportingHooks.settingsFile,
              Set(grant.hooks.keys) == Set(ReportingHooks.events) else { throw ReportingError.invalidResponse }
        for (_, groups) in grant.hooks {
            guard !groups.isEmpty else { throw ReportingError.invalidResponse }
            for group in groups {
                guard !group.hooks.isEmpty else { throw ReportingError.invalidResponse }
                for hook in group.hooks {
                    guard hook.type == "command", hook.command.count <= 8192, !hook.command.contains("\n"),
                          ReportingHooks.isReportingCommand(hook.command) else { throw ReportingError.invalidResponse }
                }
            }
        }
        return grant
    }

    public func revoke(_ credential: ConnectionCredential, keyID: String) async throws -> ReportingKey {
        guard keyID.range(of: "^[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil else { throw ReportingError.invalidResponse }
        struct Revoked: Decodable { let workspace_id: String; let key: ReportingKey }
        let result: Revoked = try decode(await request("/" + keyID, method: "DELETE", credential: credential))
        guard result.workspace_id == credential.connection.workspace.id, !result.key.active else { throw ReportingError.invalidResponse }
        return result.key
    }
}
