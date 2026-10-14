import Foundation

/// The agent apps Planisphere can connect local memory to.
enum AgentHost: String, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode
    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude Code" }
    /// Where the app keeps its settings, honoring the same overrides the app itself reads.
    var home: URL {
        let environment = ProcessInfo.processInfo.environment
        let user = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .codex: return environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? user.appendingPathComponent(".codex")
        case .claudeCode: return environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? user.appendingPathComponent(".claude")
        }
    }
    var homeFlag: String { self == .codex ? "--codex-home" : "--claude-home" }
    var installedMessage: String { "\(name) is connected." }
}

actor MemoryHostInstaller {
    static func arguments(script: URL, root: URL, home: URL, host: AgentHost, statusOnly: Bool) -> [String] {
        ["-B", script.path, "--memory-root", root.path, host.homeFlag, home.path] + (statusOnly ? ["--status"] : [])
    }

    func connect(root: URL, home: URL, host: AgentHost = .codex, statusOnly: Bool = false,
                 bundle: URL = Bundle.main.bundleURL) throws -> String {
        let packaged = bundle.pathExtension == "app"
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = packaged ? bundle.appendingPathComponent("Contents/Resources/Host") : checkout.appendingPathComponent(".build/memory-host")
        let python = packaged ? bundle.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/bin/python3.13") : URL(fileURLWithPath: "/usr/bin/python3")
        let script = source.appendingPathComponent("planisphere_memory_setup.py")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.isExecutableFile(atPath: python.path) else {
            throw MemoryHostError.unavailable
        }
        let task = Process(), output = Pipe()
        task.executableURL = python
        task.arguments = Self.arguments(script: script, root: root, home: home, host: host, statusOnly: statusOnly)
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard data.count <= 65_536, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MemoryHostError.unavailable }
        guard task.terminationStatus == 0 else { throw MemoryHostError.setup(result["error"] as? String ?? "Setup could not finish.") }
        if statusOnly { return result["status"] as? String ?? "unknown" }
        return host.installedMessage
    }
}

enum MemoryHostError: Error, CustomStringConvertible {
    case unavailable, setup(String)
    var description: String {
        switch self {
        case .unavailable: "This build is missing its agent setup tools. Memory saved here is still available."
        case .setup(let message): message
        }
    }
}
