import AppKit
import Observation
import PlanisphereCore

struct DiscoveredVault: Identifiable, Equatable, Codable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    var selected = true
    var registeredID: UUID?
    var error: String?
}

@MainActor @Observable
final class OnboardingModel {
    struct Saved: Codable {
        var progress = OnboardingProgress()
        var operationID = UUID()
        var destination: URL?
        var purpose = ""
        var verificationStarted: Date?
        var agent: String?
        // Optional for compatibility with setup saved before source persistence.
        var candidates: [DiscoveredVault]?
        var recoveringExistingSetup: Bool?
    }
    var saved = Saved()
    var visible = false
    var loaded = false
    var busy = false
    var checking = false
    var message: String?
    var candidates: [DiscoveredVault] {
        get { saved.candidates ?? [] }
        set { saved.candidates = newValue }
    }
    var selectedAgent: AgentHost = .claudeCode
    var consent = false
    private let stateURL: URL
    private var persisted = Saved()
    var step: OnboardingProgress.Step { saved.progress.step }
    init(root: URL) { stateURL = root.appendingPathComponent("onboarding.json") }

    func load(existing: [VaultRecord]) {
        guard !loaded else { return }; loaded = true
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: stateURL))
                visible = saved.progress.step != .complete
                selectedAgent = AgentHost(rawValue: saved.agent ?? "") ?? .claudeCode
            } else {
                visible = true
                saved.recoveringExistingSetup = !existing.isEmpty
                saved.candidates = existing.map { DiscoveredVault(url: $0.url, registeredID: $0.id) }
                _ = persist()
            }
            persisted = saved
        } catch { visible = true; message = "Saved setup could not be read. " + error.localizedDescription }
    }
    /// Reuse independently observed setup; never reinstall or change an existing connection here.
    func reconcile(accountVerified: Bool, reports: [AgentHost: AgentHostReport], reportingConnected: Bool,
                   knowledge: VaultRecord? = nil, knowledgeSources: [UUID] = [], localModelInstalled: Bool = false) {
        guard !busy, step != .complete else { return }
        let before = saved.progress
        if step == .account, accountVerified { saved.progress.accountVerified(true) }
        if step == .agent, accountVerified {
            let hosts = [selectedAgent] + AgentHost.allCases.filter { $0 != selectedAgent }
            if let host = hosts.first(where: {
                canReuseAgent(reports[$0]) && ($0 != .claudeCode || reportingConnected)
            }) {
                selectedAgent = host; saved.agent = host.rawValue
                saved.progress.agentVerified(host.rawValue, successfulRun: true)
            }
        }
        // Only migrate a legacy setup. A saved wizard may intentionally be creating another home.
        if step == .existingVaults, saved.recoveringExistingSetup == true, let knowledge {
            saved.progress.sourcesSelected(knowledgeSources)
            saved.destination = knowledge.url
            saved.progress.confirmVaultSetup()
            saved.progress.finishLocalModelChoice()
            saved.progress.knowledgeCreated(knowledge.id, consented: true, verified: true)
        }
        if step == .localModel, localModelInstalled { saved.progress.finishLocalModelChoice() }
        if saved.progress != before {
            if persist(), step == .complete { visible = false }
        }
    }

    func canReuseAgent(_ report: AgentHostReport?) -> Bool {
        guard let report, report.status == "installed", !report.broken,
              let run = report.lastRun, let at = run.at, run.exitCode == 0, run.problem == nil,
              at <= Date().addingTimeInterval(60) else { return false }
        // An explicit connection attempt still needs its own successful run.
        return saved.verificationStarted.map { at >= $0.addingTimeInterval(-1) } ?? true
    }

    @discardableResult func persist() -> Bool {
        do {
            try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
            persisted = saved
            return true
        } catch { saved = persisted; message = "Setup progress could not be saved. " + error.localizedDescription; return false }
    }
    func accountVerified(_ verified: Bool) {
        guard verified else { return }
        saved.progress.accountVerified(true); _ = persist()
    }
    func discover(existing: [VaultRecord], registryURL: URL? = nil) {
        guard !busy else { return }
        let registry = registryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        let knownRecords = Set(candidates.compactMap(\.registeredID))
        var urls = existing.filter { !knownRecords.contains($0.id) }.map(\.url) + candidates.map(\.url)
        do {
            if FileManager.default.fileExists(atPath: registry.path) {
                let data = try Data(contentsOf: registry)
                guard data.count <= 2 * 1024 * 1024,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let vaults = object["vaults"] as? [String: [String: Any]] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                urls += vaults.values.compactMap { $0["path"] as? String }.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
            }
            message = nil
        } catch { message = "Automatic discovery could not finish. Retry, or choose folders manually. " + error.localizedDescription }
        var seen = Set<String>()
        candidates = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }.map { url in
            var candidate = candidates.first(where: { $0.id == url.path }) ?? DiscoveredVault(url: url)
            if let record = existing.first(where: { $0.url.standardizedFileURL.path == url.path }) {
                candidate.registeredID = record.id
            }
            return candidate
        }
        _ = persist()
    }
    func chooseFolders() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.title = "Choose existing knowledge folders"; panel.prompt = "Add to setup"
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }
    func addFolders(_ urls: [URL]) {
        guard !busy else { return }
        for url in urls.map(\.standardizedFileURL) where !candidates.contains(where: { $0.id == url.path }) {
            candidates.append(.init(url: url))
        }
        _ = persist()
    }
    func selectSource(id: String, selected: Bool) {
        guard !busy, let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].selected = selected
        _ = persist()
    }
    func selectAllSources() {
        guard !busy else { return }
        for index in candidates.indices { candidates[index].selected = true }
        _ = persist()
    }

    func registerSources(existing: [VaultRecord] = [], using register: (URL) async throws -> VaultRecord) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let sources = candidates.filter(\.selected)
        // Save the selection before the first suspension, including manual folders.
        guard persist() else { return }
        var records: [UUID] = []
        var failed = false
        for source in sources {
            do {
                let record: VaultRecord
                if let existingRecord = existing.first(where: { $0.id == source.registeredID }) {
                    record = existingRecord
                } else { record = try await register(source.url) }
                // The native store may return a canonical spelling for the same folder.
                // Associate its result with the request identity, never the current row index.
                records.append(record.id)
                if let index = candidates.firstIndex(where: { $0.id == source.id }) {
                    candidates[index].registeredID = record.id
                    candidates[index].error = nil
                }
            } catch {
                failed = true
                if let index = candidates.firstIndex(where: { $0.id == source.id }) {
                    candidates[index].error = error.localizedDescription
                }
            }
            // Preserve partial success and failures even when registration is interrupted.
            guard persist() else { return }
        }
        guard Set(candidates.filter(\.selected).map(\.id)) == Set(sources.map(\.id)) else {
            message = "Source choices changed while folders were being added. Review your selection and continue again."
            return
        }
        guard !failed else {
            message = "Some folders could not be added. Retry them or deselect them to continue."
            return
        }
        saved.progress.sourcesSelected(records)
        if saved.destination == nil {
            saved.destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("World Knowledge")
        }
        message = nil
        _ = persist()
    }

    func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Choose your World Knowledge home"; panel.nameFieldStringValue = "World Knowledge"
        panel.canCreateDirectories = true; panel.prompt = "Use this location"
        panel.message = "Planisphere will create a new folder here after you approve gathering context."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saved.destination = url; _ = persist()
    }
    func confirmDestination() {
        guard saved.destination != nil else { return }
        saved.progress.confirmVaultSetup(); _ = persist()
    }
    func finishModelChoice() { saved.progress.finishLocalModelChoice(); _ = persist() }

    func setupPrompt(_ host: AgentHost) -> String {
        """
        I'm connecting \(host.name) to Planisphere on this Mac. I have installed the local integration using the Planisphere app. Please check that the Planisphere memory hook has run in this fresh chat and report its actual result. If approval of a new hook is required, show the approval instead of bypassing it. Do not invent a successful connection, read my vaults yet, or paste any account keys. I will choose my source vaults and approve context gathering in Planisphere next.
        """
    }
    func copyPrompt(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        message = "Setup prompt copied."
    }
    func verifiedAgent(_ report: AgentHostReport?) -> Bool {
        guard let report, report.status == "installed", !report.broken,
              let start = saved.verificationStarted, let run = report.lastRun,
              let at = run.at, at >= start.addingTimeInterval(-1), run.exitCode == 0,
              run.problem == nil else { return false }
        return true
    }
}
