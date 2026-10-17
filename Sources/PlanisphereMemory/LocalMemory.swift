import Foundation
import Darwin

/// Mac-owned configuration. Account sign-in and existing vaults are unnecessary.
/// Host adapters receive this exact profile and helper identity; requests cannot
/// choose another database. UI work runs on an actor, away from the main thread.
public actor LocalMemory {
    public nonisolated let root: URL
    private let helper: URL

    public init(root: URL, helper: URL) { self.root = root; self.helper = helper }

    public func request(_ data: Data) throws -> Data {
        try Self.perform(root: root, helper: helper, data: data)
    }

    private nonisolated static func perform(root: URL, helper: URL, data: Data) throws -> Data {
        let directory = try PrivateDirectory(root)
        let configuration: [String: Any] = try directory.locked {
            var config = try directory.read("connection.json").map(object) ?? ["version": 1, "profile": token()]
            try require(config["version"] as? Int == 1, "Unsupported memory configuration")
            let profile = try field(config, "profile")
            // A missing debug helper still permits the UI; adapters report it as
            // unavailable. Packaged builds always contain this executable.
            // Foundation can shorten /private/tmp back to the /tmp alias even
            // after resolving a URL. Persist the filesystem's canonical string.
            if let canonical = realpath(helper.path, nil) {
                config["helper_path"] = String(cString: canonical)
                free(canonical)
            } else { config["helper_path"] = helper.path }
            config["helper_sha256"] = try? digest(Data(contentsOf: helper))
            config["profile"] = profile
            try directory.replaceConfiguration(json(config))
            return config
        }
        var input = try object(data)
        input["profile"] = configuration["profile"]
        return try json(MemoryStore(directory: root, profile: field(configuration, "profile")).handle(input))
    }
}
