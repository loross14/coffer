import Foundation
import XCTest
@testable import PlanisphereModel

/// Opt-in: PLANISPHERE_MODEL_FILE (the pinned GGUF), PLANISPHERE_MODEL_SERVER (scripts/build-model-server.sh output)
/// and PLANISPHERE_HOST_SOURCE (the pinned API internal directory). Installs into a temporary folder, serves it on
/// the pinned port, and has the host's provider verify the runtime record and make one strict-schema call.
final class RuntimeEndToEndTests: XCTestCase {
    func testHostVerifiesAndUsesTheInstalledRuntime() throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["PLANISPHERE_MODEL_FILE"], let server = env["PLANISPHERE_MODEL_SERVER"],
              let host = env["PLANISPHERE_HOST_SOURCE"] else { throw XCTSkip("Set PLANISPHERE_MODEL_FILE, PLANISPHERE_MODEL_SERVER and PLANISPHERE_HOST_SOURCE") }
        let root = URL(fileURLWithPath: ModelStore.canonical(URL(fileURLWithPath: NSTemporaryDirectory())))
            .appendingPathComponent("model-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ModelLocation(directory: root.appendingPathComponent("Models"))
        let record = try ModelStore.install(from: URL(fileURLWithPath: file), move: false, at: location)
        XCTAssertEqual(ModelStore.installed(at: location), record)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: server)
        process.arguments = ModelStore.serverArguments(record)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, (try? Data(contentsOf: URL(string: record.endpoint + "/health")!)) == nil { Thread.sleep(forTimeInterval: 0.5) }

        let check = """
        import json, sys
        sys.path.insert(0, sys.argv[1])
        import planisphere_local_support as support
        provider = support.LocalModel({"endpoint": sys.argv[3], "runtime": sys.argv[2], "model": "planisphere-support"})
        provider.probe()
        locality = provider.locality()
        assert locality["sha256"] == "8cdb57cbb880d313736a9bc4e3d3d2485f145b5e19cf33783746e753e82641fc", locality
        schema = {"type": "object", "additionalProperties": False, "required": ["ok"], "properties": {"ok": {"type": "boolean"}}}
        payload = support.encoded({"model": provider.model, "temperature": 0, "seed": 0, "max_tokens": 20, "stream": False,
            "messages": [{"role": "user", "content": "Reply with ok true as JSON."}],
            "response_format": {"type": "json_schema", "json_schema": {"name": "ok", "strict": True, "schema": schema}}})
        data = provider.exchange("POST", "/v1/chat/completions", payload=payload, headers={"Content-Type": "application/json"})
        print(json.dumps({"locality": locality, "answer": json.loads(data["choices"][0]["message"]["content"])}))
        """
        let python = Process(), output = Pipe(), errors = Pipe()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-B", "-c", check, host, location.runtimeRecord.path, record.endpoint]
        python.standardOutput = output; python.standardError = errors
        try python.run(); python.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(python.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual((result?["answer"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertNil((result?["locality"] as? [String: Any])?["deviceIdentifier"] as? String)
    }
}
