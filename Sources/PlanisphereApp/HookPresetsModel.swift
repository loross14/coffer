import Foundation
import Observation

/// The hooks Planisphere comes with. One install each; status from what the hooks record.
enum HookPreset: String, CaseIterable, Identifiable, Sendable {
    case context, support, responseCheck = "response-check"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .context: "Context provisioning"
        case .support: "Local support"
        case .responseCheck: "Response check"
        }
    }
    var summary: String {
        switch self {
        case .context: "Before each reply, the agent receives your memory and the relevant vault context."
        case .support: "Planisphere's local model prepares that context in the background, on this Mac."
        case .responseCheck: "A second pair of eyes on each reply before it lands. With Local support on, the local model reads it too."
        }
    }
    var symbol: String {
        switch self {
        case .context: "point.3.connected.trianglepath.dotted"
        case .support: "cpu"
        case .responseCheck: "checkmark.shield"
        }
    }
}

/// One preset's state for one agent app, as the host tools report it from their own files.
struct HookPresetStatus: Decodable, Sendable, Equatable {
    struct Failure: Decodable, Sendable, Equatable {
        let at: Double
        let message: String
    }
    let id: String
    /// installed, disabled, not_installed or unknown.
    let installed: String
    let runs: Int
    let last_run: Double?
    let last_error: Failure?
    /// Local support only: observe or optimize.
    var mode: String?
    /// Local support only: ready, not_running or not_installed.
    var model: String?
    /// Response check only: whether the local model reads each reply.
    var model_review: Bool?

    init(id: String, installed: String, runs: Int = 0, last_run: Double? = nil, last_error: Failure? = nil,
         mode: String? = nil, model: String? = nil, model_review: Bool? = nil) {
        self.id = id; self.installed = installed; self.runs = runs; self.last_run = last_run
        self.last_error = last_error; self.mode = mode; self.model = model; self.model_review = model_review
    }
}

struct HookPresetReport: Decodable, Sendable {
    let host: String
    let presets: [HookPresetStatus]
}

actor HookPresetsService {
    static func arguments(script: URL, root: URL, home: URL, host: AgentHost, runtime: URL, install: HookPreset?) -> [String] {
        ["-B", script.path, "--memory-root", root.path, host.homeFlag, home.path, "--runtime", runtime.path]
            + (install.map { ["--install", $0.rawValue] } ?? [])
    }

    func run(root: URL, home: URL, host: AgentHost, runtime: URL, install: HookPreset? = nil,
             bundle: URL = Bundle.main.bundleURL) throws -> HookPresetReport {
        let packaged = bundle.pathExtension == "app"
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = packaged ? bundle.appendingPathComponent("Contents/Resources/Host") : checkout.appendingPathComponent(".build/memory-host")
        let python = packaged ? bundle.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/bin/python3.13") : URL(fileURLWithPath: "/usr/bin/python3")
        let script = source.appendingPathComponent("planisphere_hook_presets.py")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.isExecutableFile(atPath: python.path) else {
            throw MemoryHostError.unavailable
        }
        let process = Process(), output = Pipe()
        process.executableURL = python
        process.arguments = Self.arguments(script: script, root: root, home: home, host: host, runtime: runtime, install: install)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard data.count <= 65_536 else { throw MemoryHostError.setup("Hook status returned too much data.") }
        if process.terminationStatus != 0 {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw MemoryHostError.setup(value?["error"] as? String ?? "Hook setup could not finish.")
        }
        return try JSONDecoder().decode(HookPresetReport.self, from: data)
    }
}

@MainActor @Observable
final class HookPresetsModel {
    private(set) var reports: [AgentHost: [HookPresetStatus]] = [:]
    private(set) var busy = false
    private(set) var checked = false
    var message: String?
    private let service = HookPresetsService()
    private let root: URL
    private let runtime: URL
    private var previewing = false

    init(root: URL, runtime: URL) {
        self.root = root
        self.runtime = runtime
    }

    func status(_ preset: HookPreset, _ host: AgentHost) -> HookPresetStatus? {
        reports[host]?.first { $0.id == preset.rawValue }
    }

    #if DEBUG
    func preview(_ reports: [AgentHost: [HookPresetStatus]], message: String? = nil) {
        previewing = true; checked = true; self.reports = reports; self.message = message
    }
    #endif

    func refresh() async {
        guard !busy, !previewing else { return }; busy = true; defer { busy = false }
        for host in AgentHost.allCases { await load(host) }
        checked = true
    }

    private func load(_ host: AgentHost) async {
        do { reports[host] = try await service.run(root: root, home: host.home, host: host, runtime: runtime).presets }
        catch { reports[host] = nil; message = String(describing: error) }
    }

    func install(_ preset: HookPreset, for host: AgentHost) async {
        guard !busy, !previewing else { return }; busy = true; defer { busy = false }
        do {
            reports[host] = try await service.run(root: root, home: host.home, host: host, runtime: runtime, install: preset).presets
            message = Self.installedMessage(preset, host)
        } catch { message = String(describing: error) }
        checked = true
    }

    /// After Connect: if the local model is installed and answering, give that agent the support hook too.
    func afterConnect(_ host: AgentHost) async {
        guard !previewing else { return }
        busy = true
        await load(host)
        busy = false
        if let support = status(.support, host), support.model == "ready", support.installed == "not_installed" {
            await install(.support, for: host)
        }
    }

    static func installedMessage(_ preset: HookPreset, _ host: AgentHost) -> String {
        let review = host == .codex ? "Review the hooks in Codex, then start a new chat." : "Start a new session; if asked, review the hooks in /hooks."
        return "\(preset.name) is installed for \(host.name). \(review) Runs appear here once the hook records them."
    }

    /// The one line under each agent: what is installed, what ran, what failed. Nothing reads as working without a recorded run.
    static func line(_ status: HookPresetStatus?, preset: HookPreset, host: AgentHost, context: HookPresetStatus?, now: Date = Date()) -> String {
        guard let status else { return "Status not checked yet" }
        if status.installed == "unknown" { return "Status could not be read" + (status.last_error.map { ": " + $0.message } ?? "") }
        let runs: String = {
            guard status.runs > 0, let last = status.last_run else { return "no runs recorded yet" }
            let unit = switch preset { case .context: "turn"; case .support: "preparation"; case .responseCheck: "check" }
            return "\(status.runs) \(unit)\(status.runs == 1 ? "" : "s") · last ran \(relative(last, now: now))"
        }()
        var line: String
        switch (preset, status.installed) {
        case (.support, "not_installed"):
            switch status.model {
            case "not_installed": line = "Install the Planisphere model in Local first"
            case "not_running": line = "Start the Planisphere model in Local first"
            default: line = context?.installed == "installed" ? "Not installed" : "Install Context provisioning first"
            }
        case (.responseCheck, "not_installed"):
            line = context?.installed == "installed" ? "Not installed" : "Install Context provisioning first"
        case (_, "not_installed"): line = "Not installed"
        case (.support, "disabled"): line = "Installed, but support is paused · \(runs)"
        case (_, "disabled"): line = "Installed, but turned off in \(host.name) · \(runs)"
        case (.support, _):
            let mode = status.mode == "optimize" ? "prepared evidence in use" : "observing, delivery unchanged"
            line = "Installed · \(mode) · \(runs)"
            if status.model == "not_running" { line += " · model not running" }
        case (.responseCheck, _):
            line = "Installed · \(status.model_review == true ? "the local model reads each reply" : "format checks only; turn on Local support for the model review") · \(runs)"
        default: line = "Installed · \(runs)"
        }
        if let error = status.last_error, status.installed != "not_installed" || preset == .context {
            line += " · Last error \(relative(error.at, now: now)): \(error.message)"
        }
        return line
    }

    static func relative(_ epoch: Double, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: epoch), relativeTo: now)
    }
}
