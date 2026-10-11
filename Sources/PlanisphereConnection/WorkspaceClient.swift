import Foundation

public enum WorkspaceError: Error, LocalizedError, Equatable {
    case permissionRequired, unavailable, invalidResponse, signInAgain
    public var errorDescription: String? {
        switch self {
        case .permissionRequired: "Reconnect and approve read access for this view."
        case .unavailable: "Workspace data is unavailable. Check your connection and try again."
        case .invalidResponse: "Workspace data could not be read safely. Try again after updating the app."
        case .signInAgain: "This connection has expired or was disconnected. Sign in again."
        }
    }
}

public struct PromptCoverage: Codable, Sendable {
    public let status: String
    public let limitations: [String]
}
public struct UsageMetric: Codable, Sendable {
    public let observed: Double?
    public let estimated: Double?
    public let missing_observations: Int?
}
public struct PromptUsage: Codable, Sendable {
    public let observations: Int
    public let metrics: [String: UsageMetric]
}
public struct PromptCall: Codable, Sendable, Identifiable {
    public var id: String { source_id }
    public let source_id: String
    public let provider: String?
    public let model: String?
    public let status: String
    public let measurement: String
    public let input_tokens: Double?
    public let output_tokens: Double?
}
public struct RemotePrompt: Codable, Sendable, Identifiable {
    public var id: String { usage_id }
    public let usage_id: String
    public let prompt_id: String
    public let session_id: String
    public let agent_system: String
    public let system_id: String
    public let status: String
    public let started_at: String?
    public let ended_at: String?
    public let coverage: PromptCoverage
    public let summary: PromptUsage
    public let bound_receipt_id: String?
    public let calls: [PromptCall]?
}
public struct PromptPage: Codable, Sendable {
    public let workspace_id: String
    public let prompts: [RemotePrompt]
    public let next_cursor: String?
    public let coverage: String
}
public struct PromptDetail: Codable, Sendable {
    public let workspace_id: String
    public let prompt: RemotePrompt
}
public struct HookActivity: Codable, Sendable, Identifiable {
    public var id: String { system_id }
    public let system_id: String
    public let records_24h: Int
    public let last_recorded_at: String?
    public let last_event_type: String?
    public let observed_connector: String?
    public let observed_environment: String?
}
public struct HookPage: Codable, Sendable {
    public let workspace_id: String
    public let systems: [HookActivity]
    public let truncated: Bool
    public let coverage: String
}
public struct PromptFilter: Sendable, Equatable {
    public var query = ""
    public var agent = ""
    public var source = ""
    public var status = ""
    public var days: Int? = nil
    public init() {}
}

private final class WorkspaceNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct WorkspaceClient: Sendable {
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: WorkspaceNoRedirects(), delegateQueue: nil)
        send = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WorkspaceError.invalidResponse }
            return (data, http)
        }
    }
    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) { self.send = send }
    private func get<T: Decodable>(_ path: String, credential: ConnectionCredential, scope: String,
                                   items: [URLQueryItem] = []) async throws -> T {
        guard credential.connection.permissions.contains(scope) else { throw WorkspaceError.permissionRequired }
        var components = URLComponents(url: ConsoleClient.production.appendingPathComponent("mac/workspace" + path), resolvingAgainstBaseURL: false)!
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: (Data, HTTPURLResponse)
        do { result = try await send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw WorkspaceError.unavailable }
        let (data, response) = result
        guard response.url == request.url else { throw WorkspaceError.invalidResponse }
        if response.statusCode == 401 { throw WorkspaceError.signInAgain }
        if response.statusCode == 403 { throw WorkspaceError.permissionRequired }
        if response.statusCode >= 500 || response.statusCode == 404 || response.statusCode == 429 { throw WorkspaceError.unavailable }
        guard response.statusCode == 200, data.count <= 8 * 1024 * 1024 else { throw WorkspaceError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw WorkspaceError.invalidResponse }
    }
    public func prompts(_ credential: ConnectionCredential, filter: PromptFilter, before: String? = nil) async throws -> PromptPage {
        var items = [URLQueryItem(name: "limit", value: "30")]
        for (name, value) in [("q", filter.query), ("agent", filter.agent), ("source", filter.source), ("status", filter.status)] where !value.isEmpty {
            items.append(URLQueryItem(name: name, value: value))
        }
        if let days = filter.days { items.append(URLQueryItem(name: "days", value: String(days))) }
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        let page: PromptPage = try await get("/prompts", credential: credential, scope: "prompts:read", items: items)
        guard page.workspace_id == credential.connection.workspace.id else { throw WorkspaceError.invalidResponse }
        return page
    }
    public func detail(_ id: String, credential: ConnectionCredential) async throws -> RemotePrompt {
        guard id.range(of: "^[A-Za-z0-9_-]{1,180}$", options: .regularExpression) != nil else { throw WorkspaceError.invalidResponse }
        let detail: PromptDetail = try await get("/prompts/" + id, credential: credential, scope: "prompts:read")
        guard detail.workspace_id == credential.connection.workspace.id, detail.prompt.id == id else { throw WorkspaceError.invalidResponse }
        return detail.prompt
    }
    public func hooks(_ credential: ConnectionCredential) async throws -> HookPage {
        let page: HookPage = try await get("/hooks", credential: credential, scope: "hooks:read")
        guard page.workspace_id == credential.connection.workspace.id else { throw WorkspaceError.invalidResponse }
        return page
    }
}
