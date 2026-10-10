import Foundation
import Darwin

/// A fresh, explicitly scoped local toolkit process for every operation.
/// No shell evaluation, network transport, key generation or Git initialization.
public actor GrapheineService {
    private let helperURL: URL
    private let engineURL: URL
    private let pythonURL: URL

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Grapheine", isDirectory: true)
        let resources = bundled.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bridge.py").path) ? $0 : nil }
        helperURL = resources?.appendingPathComponent("bridge.py") ?? checkout.appendingPathComponent("Integrations/Grapheine/bridge.py")
        engineURL = resources?.appendingPathComponent("engine", isDirectory: true) ?? checkout.deletingLastPathComponent().appendingPathComponent("Grapheine", isDirectory: true)
        pythonURL = URL(fileURLWithPath: environment["PLANISPHERE_PYTHON"] ?? "/usr/bin/python3")
    }

    internal init(helperURL: URL, engineURL: URL, pythonURL: URL) {
        self.helperURL = helperURL
        self.engineURL = engineURL
        self.pythonURL = pythonURL
    }

    public func scan(vaultURL: URL, policyURL: URL? = nil) async throws -> PruningScan {
        let data = try await invoke("scan", vaultURL: vaultURL, policyURL: policyURL)
        return try Self.validatedScan(data, vaultURL: vaultURL)
    }

    public func graph(vaultURL: URL) async throws -> GraphSnapshot {
        let data = try await invoke("graph", vaultURL: vaultURL, policyURL: nil)
        return try Self.validatedGraph(data, vaultURL: vaultURL)
    }

    internal nonisolated static func validatedGraph(_ data: Data, vaultURL: URL) throws -> GraphSnapshot {
        guard data.count <= 32 * 1024 * 1024 else {
            throw GrapheineError.invalidResponse("The graph report exceeds the supported size.")
        }
        let graph = try JSONDecoder().decode(GraphSnapshot.self, from: data)
        guard graph.vaultPath == vaultURL.path, !graph.scannedAt.isEmpty, graph.scannedAt.count <= 100,
              graph.nodes.count <= 10_000, graph.edges.count <= 100_000,
              graph.totalNodeCount >= graph.nodes.count, graph.totalNodeCount <= 20_000,
              graph.totalEdgeCount >= graph.edges.count, graph.totalEdgeCount <= 1_000_000,
              graph.omittedNodeCount == graph.totalNodeCount - graph.nodes.count,
              graph.omittedEdgeCount == graph.totalEdgeCount - graph.edges.count,
              [graph.unresolvedLinkCount, graph.ambiguousLinkCount, graph.unsupportedLinkCount]
                .allSatisfy({ (0...1_000_000).contains($0) }),
              graph.limits.count <= 100, graph.limits.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            throw GrapheineError.invalidResponse("The graph report has incomplete counts or belongs to another vault.")
        }
        try validateScope(graph.scope)
        let ids = Set(graph.nodes.map(\.id))
        guard ids.count == graph.nodes.count, Set(graph.edges).count == graph.edges.count else {
            throw GrapheineError.invalidResponse("The graph report contains duplicate notes or connections.")
        }
        var incoming: [String: Int] = [:], outgoing: [String: Int] = [:]
        for edge in graph.edges {
            guard ids.contains(edge.source), ids.contains(edge.target) else {
                throw GrapheineError.invalidResponse("A graph connection points outside the returned notes.")
            }
            incoming[edge.target, default: 0] += 1
            outgoing[edge.source, default: 0] += 1
        }
        for node in graph.nodes {
            try validateRelativePath(node.id)
            let components = node.id.split(separator: "/").map(String.init)
            let basename = components.last ?? ""
            let folder = components.dropLast().joined(separator: "/")
            guard node.id.utf8.count <= 4_096, node.id.hasSuffix(".md"), node.title == String(basename.dropLast(3)),
                  node.folder == folder, node.inDegree == incoming[node.id, default: 0],
                  node.outDegree == outgoing[node.id, default: 0],
                  node.degree == node.inDegree + node.outDegree else {
                throw GrapheineError.invalidResponse("A graph note has an unsafe path or inconsistent connection counts.")
            }
        }
        return graph
    }

    private nonisolated static func validateScope(_ scope: PruningScanScope) throws {
        guard scope.kind == "markdown-discovery", scope.excludedCount >= scope.excludedPaths.count,
              scope.excludedPaths.count <= 100, scope.appliedFilters.count <= 100,
              scope.unsupportedFilters.count <= 100, scope.limitations.count <= 100,
              scope.truncated == (scope.excludedCount > scope.excludedPaths.count),
              (scope.excludedPaths + scope.appliedFilters + scope.unsupportedFilters + scope.limitations)
                .allSatisfy({ $0.utf8.count <= 8_192 }) else {
            throw GrapheineError.invalidResponse("Grapheine returned incomplete or unsupported scan coverage. Scan again with the current engine.")
        }
        for path in scope.excludedPaths {
            try validateRelativePath(path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
    }

    internal nonisolated static func validatedScan(_ data: Data, vaultURL: URL) throws -> PruningScan {
        let scan = try JSONDecoder().decode(PruningScan.self, from: data)
        guard scan.vaultPath == vaultURL.path, scan.notes >= 0, scan.totalGroups >= scan.groups.count,
              scan.groups.count <= 200, scan.authority.questions.count <= 200,
              Set(scan.groups.map(\.id)).count == scan.groups.count,
              Set(scan.authority.questions.map(\.id)).count == scan.authority.questions.count,
              ["available", "notConfigured", "unavailable"].contains(scan.authority.status),
              scan.authority.status == "available" || scan.authority.questions.isEmpty else {
            throw GrapheineError.invalidResponse("Grapheine returned a report for another folder or an incomplete count.")
        }
        try validateScope(scan.scope)
        for group in scan.groups {
            guard group.members.count <= 1_000, group.declaredCopies >= 0 else {
                throw GrapheineError.invalidResponse("Grapheine returned an incomplete candidate group.")
            }
            for path in group.members { try Self.validateRelativePath(path) }
        }
        return scan
    }

    public func prepare(vaultURL: URL, policyURL: URL, scope: String, question: String) async throws -> PruningPacket {
        let data = try await invoke("prepare", vaultURL: vaultURL, policyURL: policyURL,
                                    arguments: ["--scope", scope, "--question", question])
        let packet = try PruningPacket(data: data)
        guard packet.vaultPath == vaultURL.path, packet.scope == scope, packet.question == question else {
            throw GrapheineError.invalidResponse("The proposed changes do not belong to this vault and question.")
        }
        return packet
    }

    public func prepareLocal(vaultURL: URL, members: [String], keepPath: String, fingerprint: String) async throws -> LocalPruningPacket {
        guard members.count >= 2, members.count <= 1_000, Set(members).count == members.count,
              members.contains(keepPath), fingerprint.count == 64,
              fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw GrapheineError.refused("Choose the note to keep from the complete candidate group.")
        }
        for path in members { try Self.validateRelativePath(path) }
        let encoded = try JSONEncoder().encode(members)
        let data = try await invoke("prepare-local", vaultURL: vaultURL, policyURL: nil,
            arguments: ["--members", String(decoding: encoded, as: UTF8.self), "--keep", keepPath, "--fingerprint", fingerprint])
        let packet = try LocalPruningPacket(data: data)
        guard packet.vaultPath == vaultURL.path, packet.keepPath == keepPath,
              Set(packet.members) == Set(members) else {
            throw GrapheineError.invalidResponse("The local proposal does not match this vault and your keeper choice.")
        }
        return packet
    }

    public func verifyLocal(vaultURL: URL, packet: LocalPruningPacket) async throws -> LocalPruningPacket {
        guard packet.vaultPath == vaultURL.path else {
            throw GrapheineError.refused("The review belongs to another vault. Prepare a new review.")
        }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("local-packet.json")
        try packet.rawData.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let data = try await invoke("verify-local", vaultURL: vaultURL, policyURL: nil, arguments: ["--packet", file.path])
        let verified = try LocalPruningPacket(data: data)
        guard verified.vaultPath == packet.vaultPath, verified.digest == packet.digest,
              verified.keepPath == packet.keepPath, Set(verified.members) == Set(packet.members),
              verified.rawData == packet.rawData else {
            throw GrapheineError.refused("The reviewed changes are no longer current. Prepare and inspect a new review.")
        }
        return verified
    }

    public func apply(vaultURL: URL, policyURL: URL, packet: PruningPacket, receiptURL: URL) async throws -> PruningApplyResult {
        guard packet.vaultPath == vaultURL.path else {
            throw GrapheineError.refused("The pruning review belongs to another vault. Scan this vault again.")
        }
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("packet.json")
        try packet.rawData.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let data = try await invoke("apply", vaultURL: vaultURL, policyURL: policyURL,
                                    arguments: ["--packet", file.path, "--receipt", receiptURL.path])
        let result = try JSONDecoder().decode(PruningApplyResult.self, from: data)
        guard [40, 64].contains(result.commit.count), result.commit.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw GrapheineError.invalidResponse("Grapheine did not return a verifiable completed commit. Inspect the vault before retrying.")
        }
        return result
    }

    public func readNote(vaultURL: URL, path: String) throws -> String? {
        try Self.validateRelativePath(path)
        guard path.hasSuffix(".md") else { throw GrapheineError.refused("Choose a Markdown note from this vault.") }
        let components = vaultURL.pathComponents.dropFirst() + path.split(separator: "/").map(String.init)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw GrapheineError.unavailable("Could not open the selected folder.") }
        defer { Darwin.close(descriptor) }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index == components.count - 1 ? O_NONBLOCK : O_DIRECTORY)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else { throw GrapheineError.refused("The note is unavailable or uses a symbolic link. Scan again.") }
            Darwin.close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw GrapheineError.refused("Only regular note files can be previewed.")
        }
        guard info.st_size <= 512 * 1024 else { return nil }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw GrapheineError.unavailable("The note could not be read.") }
            if count == 0 { break }
            result.append(contentsOf: bytes.prefix(count))
            if result.count > 512 * 1024 { return nil }
        }
        guard !result.contains(0) else { return nil }
        return String(data: result, encoding: .utf8)
    }

    internal nonisolated static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.utf8.contains(0),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GrapheineError.invalidResponse("An unsafe note path was refused.")
        }
    }

    private func invoke(_ action: String, vaultURL: URL, policyURL: URL?, arguments: [String] = []) async throws -> Data {
        let helper = helperURL, engine = engineURL, python = pythonURL
        var args = [helper.path, action, "--engine-root", engine.path, "--vault", vaultURL.path]
        if let policyURL { args += ["--policy", policyURL.path] }
        args += arguments
        let worker = Task.detached(priority: .userInitiated) {
            try Self.run(python: python, helper: helper, engine: engine, arguments: args, applying: action == "apply")
        }
        // A cancelled view must stop its read worker, not just discard its result.
        // Applying is deliberately allowed to finish so a write is not interrupted.
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            if action != "apply" { worker.cancel() }
        }
    }

    private nonisolated static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Planisphere-Grapheine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Foundation can retain macOS's /var alias even after resolvingSymlinksInPath.
        // The verifier deliberately rejects symlink ancestors, including that alias.
        guard let canonical = realpath(directory.path, nil) else {
            try? FileManager.default.removeItem(at: directory)
            throw GrapheineError.unavailable("Could not resolve the private temporary folder.")
        }
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    private nonisolated static func run(python: URL, helper: URL, engine: URL, arguments: [String], applying: Bool) throws -> Data {
        if !applying { try Task.checkCancellation() }
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: helper.path),
              FileManager.default.fileExists(atPath: engine.appendingPathComponent("grapheine_authority.py").path) else {
            throw GrapheineError.unavailable("Grapheine is unavailable. This build needs its bundled engine and Python 3.9 or later. Your vault has not changed.")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output.json"), errorURL = directory.appendingPathComponent("error.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-B"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") || key.hasPrefix("PYTHON") || key.hasPrefix("GRAPHITE_") || key.hasPrefix("GRAPHEINE_") {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        // Python's admitted-note staging stays under our private directory, so
        // cancellation removes staged note bytes even if Python is terminated.
        environment["TMPDIR"] = directory.path
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch { throw GrapheineError.unavailable("Python could not start Grapheine: \(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(180)
        var interrupted = false
        while process.isRunning {
            let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if !applying && (Task.isCancelled || Date() > deadline || size > 64 * 1024 * 1024) {
                interrupted = true
                process.terminate()
                // Do not block the UI indefinitely if a subprocess cannot exit.
                for _ in 0..<40 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        if !applying { try Task.checkCancellation() }
        if interrupted {
            throw GrapheineError.unavailable(applying
                ? "Pruning did not return a completion result. The recovery checkpoint is retained. Inspect the vault and local Git history before retrying."
                : "Grapheine exceeded the scan limit. No vault files were changed.")
        }
        let data = try Data(contentsOf: outputURL)
        struct Failure: Decodable { let error: String }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw GrapheineError.refused(failure.error) }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw GrapheineError.unavailable("Grapheine could not complete this operation. \(String(detail.prefix(1200)))")
        }
        guard !data.isEmpty else { throw GrapheineError.invalidResponse("Grapheine returned no report. Try scanning again.") }
        return data
    }
}
