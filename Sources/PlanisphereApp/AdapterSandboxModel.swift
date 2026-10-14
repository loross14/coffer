import Foundation
import Observation

// Process state is protected separately so cancellation can interrupt a blocking read.
final class AdapterInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var canceled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        canceled = true
        if let process, process.isRunning { process.terminate() }
    }

    func run(_ request: Data) throws -> Data {
        let bundle = Bundle.main.bundleURL
        let packaged = bundle.pathExtension == "app"
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = packaged ? bundle.appendingPathComponent("Contents/Resources/Adapters/sandbox.py") : source.appendingPathComponent("Integrations/Adapters/sandbox.py")
        let python = packaged ? bundle.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/bin/python3.13") : URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.fileExists(atPath: helper.path), FileManager.default.isExecutableFile(atPath: python.path) else {
            throw NSError(domain: "AdapterSandbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "The adapter test runtime is missing. Reinstall Planisphere."])
        }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = python
        child.arguments = ["-I", helper.path]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        child.standardInput = input; child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if canceled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer { lock.lock(); process = nil; lock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        lock.lock(); let wasCanceled = canceled; lock.unlock()
        if wasCanceled { throw CancellationError() }
        guard !data.isEmpty else {
            throw NSError(domain: "AdapterSandbox", code: 2, userInfo: [NSLocalizedDescriptionKey: "The test runtime stopped before returning a result."])
        }
        return data
    }
}

@MainActor @Observable
final class AdapterSandboxModel {
    static let shared = AdapterSandboxModel()
    enum Kind: String, CaseIterable { case integration = "Integration adapters", model = "Model adapters" }
    var kind: Kind = .integration
    var executable = "/usr/bin/true"
    var arguments = "[]"
    var input = "{\n  \"session_id\": \"sandbox-example\",\n  \"cwd\": \"/sandbox\",\n  \"hook_event_name\": \"UserPromptSubmit\",\n  \"prompt\": \"Hello from the adapter sandbox\"\n}"
    var host = "codex"
    var endpoint = "http://127.0.0.1:41234"
    var token = ""
    var selectedModel = ""
    var prompt = "Reply with one sentence confirming this test reached you."
    var maxTokens = 256
    private(set) var models: [String] = []
    private(set) var busy = false
    private(set) var result = "Run a test to see its output, timing and coverage here."
    private(set) var status = "Ready"
    @ObservationIgnored private var invocation: AdapterInvocation?
    @ObservationIgnored private var inventoryEndpoint = ""
    @ObservationIgnored private var inventoryToken = ""

    var inventoryCurrent: Bool { endpoint == inventoryEndpoint && token == inventoryToken }

    func run(_ action: String) {
        guard !busy else { return }
        do {
            var request: [String: Any] = ["action": action]
            if action == "execute" {
                let parsed = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
                guard let args = parsed as? [String] else { throw SandboxInputError.arguments }
                request.merge(["executable": executable, "arguments": args, "input": input, "timeout": 15]) { _, new in new }
            } else if action == "fixture" {
                request.merge(["host": host, "input": input]) { _, new in new }
            } else {
                request.merge(["endpoint": endpoint, "token": token, "model": selectedModel, "input": prompt, "max_tokens": maxTokens]) { _, new in new }
            }
            let data = try JSONSerialization.data(withJSONObject: request)
            guard data.count <= 262144 else { throw SandboxInputError.size }
            let runner = AdapterInvocation()
            invocation = runner; busy = true; status = "Running…"; result = ""
            let usedEndpoint = endpoint, usedToken = token
            Task {
                defer { busy = false; invocation = nil }
                do {
                    let output = try await Task.detached(priority: .userInitiated) { try runner.run(data) }.value
                    guard let response = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw SandboxInputError.response }
                    if response["ok"] as? Bool != true {
                        status = "Test failed"
                        result = response["error"] as? String ?? "Invalid test response."
                        if action == "models" { models = []; selectedModel = "" }
                        return
                    }
                    let body = response["result"] as? [String: Any] ?? [:]
                    if action == "models" {
                        models = body["models"] as? [String] ?? []
                        inventoryEndpoint = usedEndpoint; inventoryToken = usedToken
                        if !models.contains(selectedModel) { selectedModel = models.first ?? "" }
                    }
                    let pretty = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    result = String(decoding: pretty, as: UTF8.self)
                    if action == "execute", body["outcome"] as? String != "completed" || body["exit_code"] as? Int != 0 {
                        status = "Run needs attention"
                    } else { status = action == "fixture" ? "Envelope checked" : "Test completed" }
                } catch is CancellationError {
                    status = "Canceled"; result = "The local test was canceled. A model server may continue generation after disconnection."
                } catch { status = "Test failed"; result = error.localizedDescription }
            }
        } catch { status = "Check input"; result = error.localizedDescription }
    }

    func cancel() { invocation?.cancel(); status = "Canceling…" }
    enum SandboxInputError: LocalizedError {
        case arguments, size, response
        var errorDescription: String? {
            switch self {
            case .arguments: "Arguments must be a JSON array of strings, such as [\"--version\"]."
            case .size: "The request is too large. Keep input under 64 KiB."
            case .response: "The test runtime returned an invalid response."
            }
        }
    }
}
