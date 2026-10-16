import AppKit
import Observation
import PlanisphereCore

struct DiscoveredVault: Identifiable, Equatable {
    var id: String { url.path }
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
    }
    var saved = Saved()
    var visible = false
    var loaded = false
    var busy = false
    var message: String?
    var candidates: [DiscoveredVault] = []
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
            } else { visible = existing.isEmpty }
            persisted = saved
        } catch { visible = true; message = "Saved setup could not be read. " + error.localizedDescription }
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
        let registry = registryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        var urls = existing.map(\.url) + candidates.map(\.url)
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
            candidates.first(where: { $0.url == url }) ?? DiscoveredVault(url: url, registeredID: existing.first(where: { $0.url == url })?.id)
        }
    }
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.title = "Choose existing knowledge folders"; panel.prompt = "Add to setup"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !candidates.contains(where: { $0.url == url }) { candidates.append(.init(url: url)) }
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
