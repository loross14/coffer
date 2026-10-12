import Foundation

actor MemoryHostInstaller {
    func connect(root: URL, home: URL, statusOnly: Bool = false, bundle: URL = Bundle.main.bundleURL) throws -> String {
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
        task.arguments = ["-B", script.path, "--memory-root", root.path, "--codex-home", home.path]
        if statusOnly { task.arguments?.append("--status") }
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard data.count <= 65_536, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MemoryHostError.unavailable }
        guard task.terminationStatus == 0 else { throw MemoryHostError.setup(result["error"] as? String ?? "Setup could not finish.") }
        if statusOnly { return result["status"] as? String ?? "unknown" }
        return "Installed. Review the new hooks in Codex, then start a new chat. Automatic memory access has not yet been verified."
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
