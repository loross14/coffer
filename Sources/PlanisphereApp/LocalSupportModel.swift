import Foundation
import Observation

struct SupportModelChoice: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct SupportStatus: Codable, Sendable {
    let enabled: Bool
    let mode: String
    let model: String
    let models: [SupportModelChoice]
    let retrieval_connections: Int
    let linked_connections: Int
    let issue: String?
}

actor LocalSupportService {
    func request(root: URL, home: URL, mode: String? = nil, model: String = "", inventory: Bool = true) throws -> Data {
        let bundle = Bundle.main.bundleURL
        let packaged = bundle.pathExtension == "app"
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = packaged ? bundle.appendingPathComponent("Contents/Resources/Host") : checkout.appendingPathComponent(".build/memory-host")
        let python = packaged ? bundle.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/bin/python3.13") : URL(fileURLWithPath: "/usr/bin/python3")
        let script = source.appendingPathComponent("planisphere_support_settings.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw MemoryHostError.setup("This build does not include local support setup.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = python
        process.arguments = ["-B", script.path, "--memory-root", root.path, "--codex-home", home.path]
        if let mode { process.arguments! += ["--mode", mode, "--model", model] }
        if !inventory && mode == nil { process.arguments?.append("--configuration-only") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard data.count <= 65_536 else { throw MemoryHostError.setup("Local support returned too much data.") }
        if process.terminationStatus != 0 {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw MemoryHostError.setup(value?["error"] as? String ?? "Local support setup could not finish.")
        }
        return data
    }
}

@MainActor @Observable
final class LocalSupportModel {
    private(set) var status: SupportStatus?
    private(set) var busy = false
    var message: String?
    var selectedModel = ""
    private let service = LocalSupportService()
    private let root: URL
    private let home: URL

    init(root: URL) {
        self.root = root
        home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func refresh(inventory: Bool = true) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let value = try JSONDecoder().decode(SupportStatus.self, from: await service.request(root: root, home: home, inventory: inventory))
            status = value
            if selectedModel.isEmpty || !value.models.contains(where: { $0.id == selectedModel }) {
                selectedModel = value.models.contains(where: { $0.id == value.model }) ? value.model : value.models.first?.id ?? ""
            }
            message = value.issue
        } catch { message = String(describing: error) }
    }

    func configure(_ mode: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            status = try JSONDecoder().decode(SupportStatus.self, from: await service.request(root: root, home: home, mode: mode, model: selectedModel))
            message = mode == "off" ? "Support is paused. No new preparation will start; a request already running may finish."
                : "Setup saved. Review the updated hooks in Codex, then start a new chat. Automatic execution has not yet been verified."
        } catch { message = String(describing: error) }
    }
}
