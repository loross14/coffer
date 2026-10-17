import CryptoKit
import Foundation

/// The one model Planisphere runs on this Mac. The file is pinned by size and SHA-256,
/// and the bundled llama.cpp server serves it on a fixed loopback port.
public struct ModelSpec: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let modelKey: String
    public let fileName: String
    public let source: URL
    public let sha256: String
    public let sizeBytes: Int64
    public let contextLength: Int
    public let port: Int

    public init(identifier: String, name: String, modelKey: String, fileName: String, source: URL,
                sha256: String, sizeBytes: Int64, contextLength: Int, port: Int) {
        self.identifier = identifier; self.name = name; self.modelKey = modelKey; self.fileName = fileName
        self.source = source; self.sha256 = sha256; self.sizeBytes = sizeBytes
        self.contextLength = contextLength; self.port = port
    }

    // Same file LM Studio served for the October 2026 reviewer evaluations (Apache-2.0 base model).
    public static let builtIn = ModelSpec(
        identifier: "planisphere-support", name: "Qwen3 4B Instruct", modelKey: "Qwen3-4B-Instruct-2507-Q4_K_M",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        source: URL(string: "https://huggingface.co/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/resolve/4edb920b6f14e3b9284d4502a6485103d72cde05/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        sha256: "8cdb57cbb880d313736a9bc4e3d3d2485f145b5e19cf33783746e753e82641fc",
        sizeBytes: 2_497_280_448, contextLength: 8192, port: 41234)

    public var endpoint: String { "http://127.0.0.1:\(port)" }
}

/// The private record the host's local-support code reads to verify the served model.
public struct RuntimeRecord: Codable, Equatable, Sendable {
    public var version = 1
    public let identifier: String
    public let name: String
    public let model: String
    public let endpoint: String
    public let path: String
    public let sha256: String
    public let sizeBytes: Int64
    public let contextLength: Int
}

public struct ModelLocation: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// `<data directory>/Models`, where the data directory defaults to Application Support/Planisphere.
    public static func standard(dataDirectory: URL? = nil) -> ModelLocation {
        let data = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Planisphere", isDirectory: true)
        return ModelLocation(directory: data.appendingPathComponent("Models", isDirectory: true))
    }

    public var runtimeRecord: URL { directory.appendingPathComponent("runtime.json") }
    public func modelFile(_ spec: ModelSpec) -> URL { directory.appendingPathComponent(spec.fileName) }
}

public enum ModelError: LocalizedError, Equatable {
    case wrongSize, checksumMismatch, notInstalled

    public var errorDescription: String? {
        switch self {
        case .wrongSize: "The model file is incomplete. Download it again."
        case .checksumMismatch: "The model file does not match Planisphere's pinned fingerprint, so it was not used."
        case .notInstalled: "The Planisphere model is not installed."
        }
    }
}

public enum ModelStore {
    public static func sha256(of url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Double(max(1, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1))
        var hasher = SHA256(), done = 0.0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            done += Double(chunk.count)
            progress?(min(1, done / total))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stages the file inside the model directory (a move, or an APFS clone when copying),
    /// verifies size and fingerprint, then publishes the model and its runtime record.
    @discardableResult
    public static func install(from source: URL, move: Bool, spec: ModelSpec = .builtIn, at location: ModelLocation,
                               progress: (@Sendable (Double) -> Void)? = nil) throws -> RuntimeRecord {
        let manager = FileManager.default
        try manager.createDirectory(at: location.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = location.directory.appendingPathComponent(".\(spec.fileName).\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staged) }
        if move { try manager.moveItem(at: source, to: staged) } else { try manager.copyItem(at: source, to: staged) }
        let size = (try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard size == spec.sizeBytes else { throw ModelError.wrongSize }
        guard try sha256(of: staged, progress: progress) == spec.sha256 else { throw ModelError.checksumMismatch }
        let destination = location.modelFile(spec)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: staged, to: destination)
        let record = RuntimeRecord(identifier: spec.identifier, name: spec.name, model: spec.modelKey, endpoint: spec.endpoint,
                                   path: canonical(destination), sha256: spec.sha256, sizeBytes: spec.sizeBytes,
                                   contextLength: spec.contextLength)
        try write(record, to: location.runtimeRecord)
        return record
    }

    /// The installed model, when its record matches the pinned spec and the file is complete.
    /// The fingerprint is checked at install time, not on every launch.
    public static func installed(spec: ModelSpec = .builtIn, at location: ModelLocation) -> RuntimeRecord? {
        guard let data = try? Data(contentsOf: location.runtimeRecord),
              let record = try? JSONDecoder().decode(RuntimeRecord.self, from: data),
              record.version == 1, record.identifier == spec.identifier, record.sha256 == spec.sha256,
              record.endpoint == spec.endpoint, record.path == canonical(location.modelFile(spec)),
              let size = try? URL(fileURLWithPath: record.path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == spec.sizeBytes else { return nil }
        return record
    }

    public static func remove(spec: ModelSpec = .builtIn, at location: ModelLocation) throws {
        for url in [location.runtimeRecord, location.modelFile(spec)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// A copy already on this Mac with the right size, such as one an earlier tool downloaded.
    /// It is only a source to verify and copy; nothing runs from its location.
    public static func existingCopies(spec: ModelSpec = .builtIn, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let candidates = [home.appendingPathComponent(".lmstudio/models/lmstudio-community/Qwen3-4B-Instruct-2507-GGUF/\(spec.fileName)"),
                          home.appendingPathComponent("Downloads/\(spec.fileName)")]
        return candidates.filter { url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == spec.sizeBytes
        }
    }

    public static func serverArguments(_ record: RuntimeRecord, spec: ModelSpec = .builtIn) -> [String] {
        ["--model", record.path, "--host", "127.0.0.1", "--port", String(spec.port), "--alias", record.identifier,
         "--ctx-size", String(record.contextLength), "--parallel", "1", "--n-gpu-layers", "999",
         "--no-webui", "--offline", "--log-disable"]
    }

    /// Foundation can shorten /private/var back to its /var alias; the host refuses symlinked paths,
    /// so records keep the filesystem's own spelling.
    static func canonical(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func write(_ record: RuntimeRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".runtime.\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(record),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
