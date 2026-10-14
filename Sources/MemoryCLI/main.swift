import Foundation
import PlanisphereMemory
import Darwin

// The launcher selects a private memory directory. JSON never supplies a path.
do {
    let args = CommandLine.arguments
    guard args.count == 3, args[1] == "--state-directory", args[2].hasPrefix("/") else {
        throw MemoryError.rejected("Usage: planisphere-memory --state-directory /absolute/private/memory-root < request.json")
    }
    let raw = FileHandle.standardInput.readData(ofLength: 65_537)
    guard raw.count <= 65_536, let request = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let profile = request["profile"] as? String else {
        throw MemoryError.rejected("Expected bounded JSON request with profile")
    }
    let store = try MemoryStore(directory: URL(fileURLWithPath: args[2]), profile: profile)
    #if DEBUG
    store.failurePoint = { phase in
        if ProcessInfo.processInfo.environment["PLANISPHERE_MEMORY_TEST_CRASH"] == phase { _exit(86) }
    }
    #endif
    let result = try store.handle(request)
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
} catch {
    let result: [String: Any] = ["status": "rejected", "error": String(describing: error)]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    exit(1)
}
