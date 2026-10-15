import AppKit
import Foundation
import Observation
import PlanisphereModel
import ServiceManagement

/// The launchd registration behind the model's login item. `SMAppService` in the app;
/// a stub in tests, since registering real background items is not something a test may do.
@MainActor
protocol BackgroundItem: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: BackgroundItem {}

/// Planisphere's own model: install it once (download or a verified existing copy), then run it
/// as a background item so connected agents can use it while the app is closed.
@MainActor @Observable
final class ModelRuntimeModel {
    enum Phase: Equatable {
        case checking, notInstalled, installing(String, Double?), installed, starting, running, failed(String)
    }

    struct Reply: Equatable {
        let text: String
        let seconds: Double
        let tokens: Int?
    }

    let spec = ModelSpec.builtIn
    let location: ModelLocation
    private(set) var phase: Phase = .checking
    private(set) var record: RuntimeRecord?
    private(set) var existingCopy: URL?
    private(set) var needsApproval = false
    private(set) var lastReply: Reply?
    private(set) var asking = false
    private(set) var askError: String?
    /// Agent hook configurations (Codex, Claude Code) whose settings point at this model.
    private(set) var agentHooks = 0
    private var work: Task<Void, Never>?
    private let service: BackgroundItem
    private let home: URL

    init(location: ModelLocation, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         service: BackgroundItem = SMAppService.agent(plistName: "ooo.planisphere.model.plist")) {
        self.location = location
        self.home = home
        self.service = service
    }

    var busy: Bool {
        switch phase { case .installing, .starting, .checking: true; default: false }
    }

    /// Fixed states for rendering review screenshots; live refreshes stop once set.
    private(set) var previewing = false
    #if DEBUG
    func preview(_ phase: Phase, record: RuntimeRecord?, existingCopy: URL? = nil, reply: Reply? = nil, agentHooks: Int = 0) {
        previewing = true
        self.phase = phase; self.record = record; self.existingCopy = existingCopy
        lastReply = reply; self.agentHooks = agentHooks
    }
    #endif

    var fingerprint: String { "\(spec.sha256.prefix(8))…\(spec.sha256.suffix(4))" }

    /// One stateless question to the running model, timed end to end.
    func ask(_ prompt: String) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking, phase == .running, let record,
              let url = URL(string: record.endpoint + "/v1/chat/completions") else { return }
        asking = true; askError = nil
        defer { asking = false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": record.identifier, "temperature": 0.3, "max_tokens": 300, "stream": false,
            "messages": [["role": "user", "content": text]]])
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = ((body["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            else { throw URLError(.badServerResponse) }
            let tokens = (body["usage"] as? [String: Any])?["completion_tokens"] as? Int
            lastReply = Reply(text: message.trimmingCharacters(in: .whitespacesAndNewlines),
                              seconds: Date().timeIntervalSince(started), tokens: tokens)
        } catch {
            askError = "The model didn't answer. Check that it's running, then try again."
        }
    }

    /// Counts hook settings that reach this model, directly or through Memory's local support setting.
    func scanAgentHooks() async {
        guard !previewing else { return }
        let home = home, needles = [location.runtimeRecord.path, spec.endpoint]
        agentHooks = await Task.detached { Self.hookSettingsUsingModel(home: home, needles: needles) }.value
    }

    nonisolated static func hookSettingsUsingModel(home: URL, needles: [String]) -> Int {
        func small(_ url: URL) -> String? {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 262_144 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        func mentions(_ text: String) -> Bool { needles.contains { text.contains($0) } }
        var settings = Set<String>()
        for file in [home.appendingPathComponent(".codex/hooks.json"), home.appendingPathComponent(".claude/settings.json")] {
            guard let text = small(file) else { continue }
            let words = text.replacingOccurrences(of: "\\\"", with: " ").split(whereSeparator: { " \"'".contains($0) })
            for (index, word) in words.enumerated() where word == "--settings" && index + 1 < words.count {
                settings.insert(String(words[index + 1]))
            }
        }
        return settings.filter { path in
            guard let text = small(URL(fileURLWithPath: path)) else { return false }
            if mentions(text) { return true }
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let linked = object["local_support_connection"] as? String,
                  let connection = small(URL(fileURLWithPath: linked)) else { return false }
            return mentions(connection)
        }.count
    }

    func refresh() async {
        guard work == nil, !previewing else { return }
        let location = location, spec = spec
        record = await Task.detached { ModelStore.installed(spec: spec, at: location) }.value
        existingCopy = record == nil ? ModelStore.existingCopies(spec: spec).first : nil
        needsApproval = service.status == .requiresApproval
        guard let record else { phase = .notInstalled; return }
        phase = await Self.serving(record) ? .running : .installed
    }

    func useExistingCopy() {
        guard let source = existingCopy else { return }
        install(label: "Checking the copy on this Mac…") { location, spec, progress in
            try ModelStore.install(from: source, move: false, spec: spec, at: location, progress: progress)
        }
    }

    func download() {
        install(label: "Downloading…") { [weak self] location, spec, progress in
            let file = try await ModelDownload.fetch(spec.source, into: location) { fraction in
                progress(fraction)
                Task { @MainActor in self?.phase = .installing("Downloading…", fraction) }
            }
            await MainActor.run { self?.phase = .installing("Checking the download…", nil) }
            return try ModelStore.install(from: file, move: true, spec: spec, at: location) { _ in }
        }
    }

    func cancel() { work?.cancel() }

    func start() async {
        guard record != nil else { return }
        phase = .starting
        do {
            if service.status == .enabled { try await service.unregister() }
            try service.register()
        } catch {
            needsApproval = service.status == .requiresApproval
            phase = needsApproval ? .installed : .failed("Planisphere could not start its model. \(error.localizedDescription)")
            return
        }
        needsApproval = service.status == .requiresApproval
        for _ in 0..<60 {
            if let record, await Self.serving(record) { phase = .running; return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        phase = needsApproval ? .installed : .failed("The model did not start within 30 seconds. Try again, or restart your Mac.")
    }

    /// After the app moved to Applications, launchd still points the login item at the old bundle
    /// path. Re-register from the new path when the item was enabled; otherwise leave it alone.
    /// Returns true when it re-registered.
    @discardableResult
    func reregisterAfterMove() async -> Bool {
        guard service.status == .enabled else { return false }
        do {
            try await service.unregister()
            try service.register()
        } catch {
            phase = .failed("Planisphere moved, but its model could not be registered from the new location. \(error.localizedDescription)")
            return false
        }
        await refresh()
        return true
    }

    func stop() async {
        try? await service.unregister()
        phase = record == nil ? .notInstalled : .installed
    }

    func remove() async {
        await stop()
        let location = location, spec = spec
        do {
            try await Task.detached { try ModelStore.remove(spec: spec, at: location) }.value
            record = nil
        } catch { phase = .failed(error.localizedDescription); return }
        await refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    private func install(label: String, _ body: @escaping @Sendable (ModelLocation, ModelSpec, @escaping @Sendable (Double) -> Void) async throws -> RuntimeRecord) {
        guard work == nil else { return }
        phase = .installing(label, nil)
        let location = location, spec = spec
        work = Task { [weak self] in
            do {
                let record = try await Task.detached {
                    try await body(location, spec) { fraction in
                        Task { @MainActor in
                            if case .installing(let text, _) = self?.phase { self?.phase = .installing(text, fraction) }
                        }
                    }
                }.value
                self?.record = record
                self?.existingCopy = nil
                self?.work = nil
                await self?.start()
            } catch {
                self?.work = nil
                self?.phase = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? .notInstalled : .failed(error.localizedDescription)
            }
        }
    }

    /// The server reports the recorded file under the recorded alias.
    nonisolated static func serving(_ record: RuntimeRecord) async -> Bool {
        guard let url = URL(string: record.endpoint + "/props") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let props = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return props["model_alias"] as? String == record.identifier && props["model_path"] as? String == record.path
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
