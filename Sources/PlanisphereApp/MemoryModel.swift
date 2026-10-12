import AppKit
import Foundation
import Observation
import PlanisphereMemory
import UniformTypeIdentifiers

struct MemoryFact: Codable, Identifiable, Sendable {
    let record_id: String
    let revision: Int
    let kind: String
    let body: String
    let scope: String
    let attribution: String
    let source_excerpt: String
    var id: String { record_id }
}

@MainActor @Observable
final class MemoryModel {
    private(set) var facts: [MemoryFact] = []
    private(set) var enabled = true
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var remaining = 0
    private(set) var pendingRepairs = 0
    private(set) var setupStatus = "unknown"
    var message: String?
    private var cursor: String?
    private let service: LocalMemory
    private let installer = MemoryHostInstaller()
    let root: URL
    private var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    init(root: URL? = nil, helper: URL? = nil) {
        let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Planisphere/Memory", isDirectory: true)
        self.root = root ?? defaultRoot
        let executable = helper ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("planisphere-memory")
        service = LocalMemory(root: self.root, helper: executable)
    }

    private func call(_ action: String, _ fields: [String: Any] = [:]) async throws -> Data {
        let input = fields.merging(["action": action]) { _, value in value }
        return try await service.request(JSONSerialization.data(withJSONObject: input))
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MemoryError.rejected("Invalid memory response") }
        return value
    }
    private func page(_ continuation: String? = nil) async throws -> (facts: [MemoryFact], cursor: String?, remaining: Int) {
        var fields: [String: Any] = ["budget_bytes": 65_536]
        if let continuation { fields["cursor"] = continuation }
        let result = try object(await call("resume", fields))
        let facts = try JSONDecoder().decode([MemoryFact].self, from: JSONSerialization.data(withJSONObject: result["records"] ?? []))
        return (facts, result["cursor"] as? String, result["remaining_items"] as? Int ?? 0)
    }
    func refresh(more: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let status = try object(await call("status"))
            enabled = status["enabled"] as? Bool ?? false
            pendingRepairs = (status["pending_projections"] as? Int ?? 0) + (status["pending_deletions"] as? Int ?? 0)
            let result = try await page(more ? cursor : nil)
            facts = more ? facts + result.facts : result.facts
            cursor = result.cursor; remaining = result.remaining; loaded = true; message = nil
            setupStatus = (try? await installer.connect(root: root, home: codexHome, statusOnly: true)) ?? "unknown"
        } catch { message = String(describing: error) }
    }
    func setEnabled(_ value: Bool) async {
        guard !busy else { return }
        do { _ = try await call("configure", ["enabled": value]); await refresh() }
        catch { message = String(describing: error) }
    }
    func connectCodex() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try await call("status")
            message = try await installer.connect(root: root, home: codexHome)
            setupStatus = (try? await installer.connect(root: root, home: codexHome, statusOnly: true)) ?? "unknown"
        } catch { message = String(describing: error) }
    }
    func save(_ body: String, replacing fact: MemoryFact?) async -> Bool {
        guard !busy else { return false }; busy = true
        do {
            _ = try await call("commit", ["record_id": fact?.id ?? UUID().uuidString,
                "expected_revision": fact?.revision ?? 0, "body": body, "source_excerpt": body,
                "kind": fact == nil ? "preference" : "correction", "scope": fact?.scope ?? "personal",
                "attribution": "human_statement", "event_id": UUID().uuidString, "operation_id": UUID().uuidString])
            busy = false; await refresh(); return true
        } catch { busy = false; message = String(describing: error); return false }
    }
    func forget(_ fact: MemoryFact) async {
        guard !busy else { return }; busy = true
        do {
            let result = try object(await call("forget", ["record_id": fact.id, "expected_revision": fact.revision,
                "scope": fact.scope, "operation_id": UUID().uuidString]))
            busy = false; await refresh()
            if result["deletion_state"] as? String != "complete" { message = "This memory is hidden. An edited copy needs review before deletion can finish." }
        } catch { busy = false; message = String(describing: error) }
    }
    func export() async {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Planisphere memories.json"
        guard panel.runModal() == .OK, let destination = panel.url, !busy else { return }
        busy = true; defer { busy = false }
        do {
            var all: [MemoryFact] = []; var next: String?
            repeat { let result = try await page(next); all += result.facts; next = result.cursor } while next != nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: destination, options: .atomic)
            message = "Exported \(all.count) memories. This separate copy remains until you delete it."
        } catch { message = String(describing: error) }
    }
}
