import Foundation
import Observation
import PlanisphereConnection

/// What this Mac remembers about the reporting key it minted; the key itself lives only in the hooks.
struct ReportingRecord: Codable, Equatable {
    var workspaceID: String
    var workspaceName: String
    var keyID: String
    var installedAt: Date
}

/// Console reporting for Claude Code on this Mac: the console's hooks, installed beside the memory hooks with a key the Mac minted.
@MainActor @Observable
final class ReportingModel {
    enum State: Equatable {
        case notLinked                      // no verified console connection
        case installedElsewhere             // the console's hooks are in settings.json, but this Mac is not linked
        case needsPermission                // linked, but activity:record was not approved
        case notConnected                   // linked with permission; hooks not installed
        case connected(workspace: String, lastDelivery: String?)
        case keyRevoked(workspace: String)  // hooks installed, but the console no longer accepts their key
        case unavailable(String)            // the settings file could not be read, or the console answered badly
    }
    private(set) var state: State = .notLinked
    private(set) var busy = false
    private(set) var record: ReportingRecord?
    var message: String?
    private var credential: ConnectionCredential?
    private let client: ReportingClient
    private let workspace: WorkspaceClient
    private let home: @MainActor () -> URL
    let stateURL: URL

    init(stateURL: URL, client: ReportingClient = ReportingClient(), workspace: WorkspaceClient = WorkspaceClient(),
         home: @escaping @MainActor () -> URL = { AgentHost.claudeCode.home }) {
        self.stateURL = stateURL; self.client = client; self.workspace = workspace; self.home = home
        record = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(ReportingRecord.self, from: $0) }
    }

    /// Whether a verified console connection is behind the current state.
    var linked: Bool {
        switch state {
        case .notLinked, .installedElsewhere: false
        case .unavailable: credential != nil
        default: true
        }
    }
    var canConnect: Bool {
        if case .notConnected = state { return true }
        if case .keyRevoked = state { return true }
        return false
    }
    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    /// Call whenever the console connection changes; the state is recomputed from the file and the console.
    func bind(_ value: ConnectionCredential?, verified: Bool) {
        let value = verified ? value : nil
        guard value?.token != credential?.token || value?.connection != credential?.connection else { return }
        credential = value
        Task { await refresh() }
    }

    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let installed: ReportingHookInstaller.Installed?
        do { installed = try ReportingHookInstaller.status(home: home()) }
        catch { state = .unavailable(String(describing: error)); return }
        guard let credential else {
            state = installed == nil ? .notLinked : .installedElsewhere
            return
        }
        let workspace = credential.connection.workspace.name
        guard credential.connection.permissions.contains(ReportingHooks.scope) else {
            state = installed == nil ? .needsPermission : .connected(workspace: workspace, lastDelivery: await lastDelivery(credential))
            return
        }
        guard let installed else { state = .notConnected; return }
        do {
            let keys = try await client.status(credential)
            let active = keys.keys.filter(\.active)
            let keyID = record?.keyID
            let stillActive = active.contains { $0.key_id == keyID } || (keyID == nil && !active.isEmpty)
            state = stillActive ? .connected(workspace: workspace, lastDelivery: await lastDelivery(credential)) : .keyRevoked(workspace: workspace)
            _ = installed
        } catch ReportingError.notOffered {
            state = .connected(workspace: workspace, lastDelivery: await lastDelivery(credential))
        } catch {
            state = .unavailable((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func lastDelivery(_ credential: ConnectionCredential) async -> String? {
        guard credential.connection.permissions.contains("hooks:read"),
              let page = try? await workspace.hooks(credential) else { return nil }
        return page.systems.first { $0.system_id == ReportingHooks.systemID }?.last_recorded_at
    }

    /// Mints a key through the console connection and installs the console's hooks. Rotates the key this Mac made before.
    func connect() async {
        guard !busy, let credential else { return }
        busy = true; message = nil
        do {
            let grant = try await client.issue(credential, replacing: record?.keyID)
            let path = try ReportingHookInstaller.install(grant.hooks, home: home())
            let saved = ReportingRecord(workspaceID: grant.workspace_id, workspaceName: credential.connection.workspace.name,
                                        keyID: grant.key.key_id, installedAt: Date())
            try persist(saved)
            message = "Claude Code now reports to \(credential.connection.workspace.name). Its hooks are in \(path.path); the workspace key is listed under Keys in the console."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        busy = false
        await refresh()
    }

    /// Revokes the key in the console (when it can) and takes the hooks out of Claude Code's settings.
    func disconnect() async {
        guard !busy else { return }
        busy = true; message = nil
        var notes: [String] = []
        if let credential, let record, credential.connection.permissions.contains(ReportingHooks.scope) {
            do { _ = try await client.revoke(credential, keyID: record.keyID) }
            catch ReportingError.notOffered { notes.append("Revoke the key under Keys in the console.") }
            catch { notes.append("The key was not revoked: " + ((error as? LocalizedError)?.errorDescription ?? String(describing: error)) + " Revoke it under Keys in the console.") }
        } else if record != nil {
            notes.append("Revoke the key under Keys in the console.")
        }
        do {
            let removed = try ReportingHookInstaller.remove(home: home())
            notes.insert(removed > 0 ? "Claude Code no longer reports from this Mac." : "No reporting hooks were installed.", at: 0)
            try persist(nil)
        } catch { notes.insert(String(describing: error), at: 0) }
        message = notes.joined(separator: " ")
        busy = false
        await refresh()
    }

    /// The console connection is about to be revoked: take reporting down first while the link can still revoke the key.
    func linkWillDisconnect(_ value: ConnectionCredential) async {
        guard record != nil || (try? ReportingHookInstaller.status(home: home())) != nil else { return }
        credential = value
        await disconnect()
    }

    private func persist(_ value: ReportingRecord?) throws {
        record = value
        if let value {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: stateURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    static func line(_ state: State) -> String {
        switch state {
        case .notLinked: "Connect this Mac to the console and this step also reports Claude Code activity there."
        case .installedElsewhere: "Reporting hooks from the console are installed. Connect this Mac to the console to see deliveries here."
        case .needsPermission: "Reporting needs the console’s approval. In the console connection, choose Switch Workspace… and approve activity recording."
        case .notConnected: "Reporting not set up"
        case .connected(let workspace, let last): "Reporting to \(workspace)" + (last.map { " · last delivery \(Self.when($0))" } ?? " · no delivery yet")
        case .keyRevoked(let workspace): "Reporting to \(workspace) stopped: its key was revoked in the console. Connect reporting again for a new key."
        case .unavailable(let detail): detail
        }
    }
    static func when(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? { formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value) }()
        guard let date else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    #if DEBUG
    func preview(_ value: State, record: ReportingRecord? = nil, message: String? = nil) { state = value; self.record = record; self.message = message }
    #endif
}
