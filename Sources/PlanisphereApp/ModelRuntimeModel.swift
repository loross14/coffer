import AppKit
import Foundation
import Observation
import PlanisphereModel
import ServiceManagement

/// Planisphere's own model: install it once (download or a verified existing copy), then run it
/// as a background item so connected agents can use it while the app is closed.
@MainActor @Observable
final class ModelRuntimeModel {
    enum Phase: Equatable {
        case checking, notInstalled, installing(String, Double?), installed, starting, running, failed(String)
    }

    let spec = ModelSpec.builtIn
    let location: ModelLocation
    private(set) var phase: Phase = .checking
    private(set) var record: RuntimeRecord?
    private(set) var existingCopy: URL?
    private(set) var needsApproval = false
    private var work: Task<Void, Never>?
    private let service = SMAppService.agent(plistName: "ooo.planisphere.model.plist")

    init(location: ModelLocation) { self.location = location }

    var busy: Bool {
        switch phase { case .installing, .starting, .checking: true; default: false }
    }

    func refresh() async {
        guard work == nil else { return }
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
        install(label: "Downloading \(Self.size(spec.sizeBytes))…") { [weak self] location, spec, progress in
            let file = try await ModelDownload.fetch(spec.source, into: location) { fraction in
                progress(fraction)
                Task { @MainActor in self?.phase = .installing("Downloading \(Self.size(spec.sizeBytes))…", fraction) }
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
