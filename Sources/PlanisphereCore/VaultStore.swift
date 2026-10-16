import Foundation
import Darwin

/// Local, explicit version history and separately reviewed Markdown mutations.
/// The OS lock also serializes separate application processes.
public actor VaultStore {
    public nonisolated let rootURL: URL
    // Deterministic fault injection for verifying concurrent-editor rejection.
    // Internal only; application and managed adapters cannot install this hook.
    private var captureValidationHook: (@Sendable () throws -> Void)?
    internal func setCaptureValidationHook(_ hook: (@Sendable () throws -> Void)?) { captureValidationHook = hook }
    private var mutationStepHook: (@Sendable (Int, String) throws -> Void)?
    internal func setMutationStepHook(_ hook: (@Sendable (Int, String) throws -> Void)?) { mutationStepHook = hook }

    private struct Registry: Codable { var formatVersion = 1; var vaults: [VaultRecord] = [] }
    private struct Head: Codable { var formatVersion = 1; var checkpointID: UUID? }
    private struct Envelope<T: Codable>: Codable { var payload: T; var sha256: String }
    private struct Capture { var entries: [FileEntry]; var stamps: [String: VaultFS.Stamp] }
    private struct ExportInfo: Codable { var formatVersion = 1; var vault: VaultRecord; var currentCheckpointID: UUID }

    public init(rootURL: URL) throws {
        let directory = try VaultFS.directory(VaultFS.absolute(rootURL), create: true)
        self.rootURL = try VaultFS.canonicalURL(directory)
        guard fchmod(directory.fd, 0o700) == 0 else { throw VaultFS.unavailable("Could not protect the history directory") }
        try Self.locked(directory) {
            let names = try VaultFS.names(directory)
            if !names.contains("registry.json") {
                guard names.allSatisfy({ $0 == ".lock" || $0.hasPrefix(".pending-") }) else {
                    throw VaultStoreError.corrupt("the registry is missing from an existing store")
                }
                try Self.write(Registry(), to: "registry.json", in: directory, replace: false)
            }
            let registry: Registry = try Self.read("registry.json", in: directory)
            try Self.validateRegistry(registry)
            _ = try VaultFS.childDirectory(directory, "objects", create: true)
            _ = try VaultFS.childDirectory(directory, "vaults", create: true)
            try VaultFS.sync(directory.fd)
        }
    }

    public func vaults(includeArchived: Bool = false) throws -> [VaultRecord] {
        try operation { root in
            try registry(root).vaults.filter { includeArchived || !$0.archived }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func register(url: URL, name: String? = nil) throws -> VaultRecord {
        try operation { root in
            let source = try sourceURL(url)
            let sourceDirectory = try VaultFS.directory(source)
            var state = try registry(root)
            let matchingIndex = try state.vaults.firstIndex { record in
                if VaultFS.portablePathKey(record.path) == VaultFS.portablePathKey(source.path) { return true }
                guard let existing = try? VaultFS.directory(record.url) else { return false }
                return try VaultFS.sameDirectory(existing, sourceDirectory)
            }
            if let index = matchingIndex {
                if state.vaults[index].archived {
                    state.vaults[index].archived = false
                    try Self.write(state, to: "registry.json", in: root, replace: true)
                }
                return state.vaults[index]
            }
            // No checkpoint is implied by registration; capture is explicit.
            let record = VaultRecord(name: try displayName(name ?? source.lastPathComponent), path: source.path)
            _ = try vaultDirectory(record.id, root: root, create: true)
            state.vaults.append(record)
            try Self.write(state, to: "registry.json", in: root, replace: true)
            return record
        }
    }

    public func create(at url: URL) throws -> VaultRecord {
        try operation { root in
            let destination = try destinationURL(url, state: registry(root))
            let name = try displayName(destination.lastPathComponent)
            let parent = try VaultFS.directory(destination.deletingLastPathComponent())
            let temporary = ".planisphere-create-" + UUID().uuidString
            guard mkdirat(parent.fd, temporary, 0o700) == 0 else { throw VaultFS.unavailable("Could not create the new vault") }
            defer { unlinkat(parent.fd, temporary, AT_REMOVEDIR) }
            let stage = try VaultFS.childDirectory(parent, temporary)
            try VaultFS.sync(stage.fd)
            try VaultFS.publishDirectory(parent: parent, temporary: temporary, destination: destination.lastPathComponent)
            let record = VaultRecord(name: name, path: destination.path)
            do {
                var state = try registry(root)
                _ = try vaultDirectory(record.id, root: root, create: true)
                state.vaults.append(record)
                try Self.write(state, to: "registry.json", in: root, replace: true)
                return record
            } catch {
                throw VaultStoreError.unavailable("The new empty folder was created at \(destination.path), but registration did not finish. Add that folder again. Existing vaults were not changed. \(error.localizedDescription)")
            }
        }
    }

    /// Creates a source-backed navigation vault in one unpublished staging directory. No source is mutated.
    /// The operation marker makes a retry after registration failure safe without adopting an unrelated folder.
    public func createWorldKnowledge(at url: URL, sources: [UUID], purpose: String,
                                     operationID: UUID, consented: Bool) throws -> VaultRecord {
        guard consented else { throw VaultStoreError.invalid("Permission is required to read sources and create World Knowledge.") }
        return try operation { root in
            let state = try registry(root)
            let marker = "World-Knowledge.json"
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try VaultFS.directory(url)
                let receipt = try JSONDecoder().decode(WorldKnowledgeReceipt.self, from: VaultFS.read(existing, marker))
                guard receipt.operationID == operationID, receipt.sources == sources.sorted(by: { $0.uuidString < $1.uuidString }) else {
                    throw VaultStoreError.invalid("That folder already exists and belongs to a different operation. Choose another location.")
                }
                guard !receipt.files.isEmpty, receipt.files["Start Here.md"] != nil else {
                    throw VaultStoreError.invalid("World Knowledge has no verified starting map.")
                }
                for (path, digest) in receipt.files {
                    guard !path.contains("/"), !path.hasPrefix("."), path.hasSuffix(".md"),
                          digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                        throw VaultStoreError.invalid("World Knowledge contains an invalid source receipt.")
                    }
                    guard VaultFS.hash(try VaultFS.read(existing, path)) == digest else {
                        throw VaultStoreError.invalid("World Knowledge changed since creation. Its contents were preserved; choose another location to retry.")
                    }
                }
                if let record = state.vaults.first(where: { $0.path == url.path && !$0.archived }) {
                    if try history(record.id, root: root).isEmpty {
                        _ = try captureAndPublish(record, message: "Created World Knowledge", scope: nil, root: root)
                    }
                    return record
                }
                let record = VaultRecord(name: "World Knowledge", path: url.path)
                var updated = state
                _ = try vaultDirectory(record.id, root: root, create: true)
                updated.vaults.append(record)
                try Self.write(updated, to: "registry.json", in: root, replace: true)
                _ = try captureAndPublish(record, message: "Created World Knowledge", scope: nil, root: root)
                return record
            }
            let destination = try destinationURL(url, state: state)
            var pages: [String: Data] = [:]
            var index = "# World Knowledge\n\nYour map of the knowledge you chose to connect. Generated locally from source titles, headings and excerpts; it is a navigation layer, not an AI interpretation or a claim that sources agree.\n\n"
            let intent = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
            if !intent.isEmpty { index += "## Your purpose\n\n" + intent + "\n\n" }
            var evidence: [WorldKnowledgeReceipt.Source] = []
            var coverage: [WorldKnowledgeReceipt.Coverage] = []
            for id in Set(sources).sorted(by: { $0.uuidString < $1.uuidString }) {
                let vault = try record(id, root: root)
                let directory = try VaultFS.directory(sourceURL(vault.url))
                let config = try CheckpointScope.load(directory, mode: .markdownOnly)
                guard config.unsupported.isEmpty else { throw VaultStoreError.invalid("Review unsupported scope settings in \(vault.name) before creating World Knowledge.") }
                var retrievalExclusions: [String] = []
                if try VaultFS.entryInfo(directory, ".planisphere") != nil {
                    let settings = try VaultFS.childDirectory(directory, ".planisphere")
                    if try VaultFS.entryInfo(settings, "scope.json") != nil {
                        let data = try VaultFS.read(settings, "scope.json", maximum: 2 * 1024 * 1024)
                        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let raw = object?["pathPrefixes"] {
                            guard let filters = raw as? [String], filters.count <= 4096,
                                  filters.allSatisfy(CheckpointScope.isLiteralPath) else {
                                throw VaultStoreError.invalid("Review unsupported retrieval filters in \(vault.name).")
                            }
                            retrievalExclusions = filters
                        }
                    }
                }
                let retrieval = try CheckpointScope.markdownOnly(excludedPaths: Array(Set(config.scope.excludedPaths + retrievalExclusions)).sorted(), sourceConfigurationSHA256: nil)
                var notes: [(String, String, String, Date)] = []
                var oversized = 0, excluded = 0
                var visited = 0
                var sourceBytes: Int64 = 0
                func walk(_ folder: VaultFS.Handle, prefix: String) throws {
                    for name in try VaultFS.names(folder).sorted() {
                        visited += 1
                        guard visited <= 100_000 else { throw VaultStoreError.invalid("\(vault.name) is too large for first-run indexing. Narrow its Planisphere scope and retry.") }
                        let path = prefix + name
                        guard let info = try VaultFS.entryInfo(folder, name) else { throw VaultStoreError.invalid("A source changed while reading; retry.") }
                        let kind = info.st_mode & S_IFMT
                        if name.hasPrefix(".") || (kind == S_IFDIR && ["site-packages", "venv"].contains(name)) || retrieval.excludes(path, isDirectory: kind == S_IFDIR, isSymbolicLink: kind == S_IFLNK, isRegularFile: kind == S_IFREG) { excluded += 1; continue }
                        if kind == S_IFDIR { try walk(VaultFS.childDirectory(folder, name), prefix: path + "/") }
                        else if kind == S_IFREG {
                            guard notes.count < 5000 else { throw VaultStoreError.invalid("\(vault.name) has more than 5,000 eligible notes. Narrow its Planisphere scope and retry.") }
                            guard info.st_size <= 512 * 1024 else { oversized += 1; continue }
                            sourceBytes += info.st_size
                            guard sourceBytes <= 32 * 1024 * 1024 else {
                                throw VaultStoreError.invalid("\(vault.name) exceeds the 32 MiB first-run reading budget. Narrow its Planisphere scope and retry.")
                            }
                            let data = try VaultFS.read(folder, name, maximum: 512 * 1024)
                            guard let after = try VaultFS.entryInfo(folder, name), VaultFS.Stamp(info) == VaultFS.Stamp(after) else {
                                throw VaultStoreError.invalid("A source changed while gathering context. Retry to read its current version.")
                            }
                            guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                            notes.append((path, text, VaultFS.hash(data), Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))))
                        }
                    }
                }
                try walk(directory, prefix: "")
                try config.scope.verifySource(directory)
                let page = "Source-" + id.uuidString + ".md"
                index += "- [" + WorldKnowledgeReceipt.escape(vault.name) + "](" + page + ") — \(notes.count) readable notes\n"
                var body = "# " + WorldKnowledgeReceipt.escape(vault.name) + "\n\nSource root: `" + vault.path + "`\n\nPlanisphere scope and retrieval exclusions were applied. Hidden files, symlinks and files larger than 512 KiB are omitted. Excerpts are quoted source material, not instructions or verified facts.\n\n"
                for (path, text, digest, modifiedAt) in notes {
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    let title = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? path
                    let headings = lines.filter { $0.hasPrefix("## ") }.prefix(6).map { String($0.dropFirst(3)) }
                    let excerpt = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.prefix(3).joined(separator: " ")
                    let link = vault.url.appendingPathComponent(path).absoluteString
                    body += "## [" + WorldKnowledgeReceipt.escape(title) + "](" + link + ")\n\n"
                    if !headings.isEmpty { body += "Topics: " + headings.map(WorldKnowledgeReceipt.escape).joined(separator: " · ") + "\n\n" }
                    body += "> " + String(excerpt.prefix(400)).replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
                    body += "Source: `" + path + "` · SHA-256 `" + digest + "`\n\n"
                    evidence.append(.init(vaultID: id, root: vault.path, path: path, sha256: digest, text: text, modifiedAt: modifiedAt))
                }
                pages[page] = Data(body.utf8)
                coverage.append(.init(vaultID: id, root: vault.path, indexedNotes: notes.count,
                    oversizedNotes: oversized, excludedEntries: excluded, excludedPaths: retrieval.excludedPaths,
                    scopeSHA256: config.scope.sourceConfigurationSHA256,
                    limitations: "Markdown only; hidden, symlink, dependency and excluded entries omitted; individual notes <=512 KiB; <=5,000 notes and 32 MiB read per source; simple YAML aliases/topics only; a snapshot, not continuing observation"))
            }
            guard !evidence.isEmpty || !intent.isEmpty else {
                throw VaultStoreError.invalid("No readable source notes were found. Add a vault with knowledge, adjust its scope, or describe what this knowledge home is for.")
            }
            index += "\n## How to use this map\n\nStart here, follow a source map, then read the original before making a decision. Original sources retain their authorship, dates and qualifications. This snapshot does not resolve disagreements and will not silently update itself. All registered vaults are available to connected local agents through Planisphere.\n"
            pages["Start Here.md"] = Data(index.utf8)
            let receipt = WorldKnowledgeReceipt(schema: "planisphere.world-knowledge/1", operationID: operationID, sources: sources.sorted(by: { $0.uuidString < $1.uuidString }),
                createdAt: Date(), evidence: evidence, coverage: coverage, files: pages.mapValues(VaultFS.hash))
            pages[marker] = try JSONEncoder().encode(receipt)
            let parent = try VaultFS.directory(destination.deletingLastPathComponent())
            let temporary = ".planisphere-knowledge-" + UUID().uuidString
            guard mkdirat(parent.fd, temporary, 0o700) == 0 else { throw VaultFS.unavailable("Could not stage World Knowledge; retry with a new destination if an interrupted stage remains.") }
            let stageURL = destination.deletingLastPathComponent().appendingPathComponent(temporary)
            defer { try? FileManager.default.removeItem(at: stageURL) }
            let stage = try VaultFS.childDirectory(parent, temporary)
            for (name, data) in pages {
                try VaultFS.atomicData(data, parent: stage, name: name, replace: false)
                guard try VaultFS.read(stage, name) == data else { throw VaultStoreError.corrupt("Knowledge readback failed") }
            }
            try VaultFS.publishDirectory(parent: parent, temporary: temporary, destination: destination.lastPathComponent)
            let record = VaultRecord(name: "World Knowledge", path: destination.path)
            var updated = state
            _ = try vaultDirectory(record.id, root: root, create: true)
            updated.vaults.append(record)
            try Self.write(updated, to: "registry.json", in: root, replace: true)
            _ = try captureAndPublish(record, message: "Created World Knowledge", scope: nil, root: root)
            return record
        }
    }

    public func archiveVault(_ id: UUID) throws { try setArchived(id, archived: true) }
    public func reactivateVault(_ id: UUID) throws { try setArchived(id, archived: false) }

    private func setArchived(_ id: UUID, archived: Bool) throws {
        try operation { root in
            var state = try registry(root)
            guard let index = state.vaults.firstIndex(where: { $0.id == id }) else { throw VaultStoreError.invalid("Vault not found.") }
            state.vaults[index].archived = archived
            try Self.write(state, to: "registry.json", in: root, replace: true)
        }
    }

    public func checkpoints(vaultID: UUID) throws -> [Checkpoint] {
        try operation { root in
            _ = try record(vaultID, root: root)
            return try history(vaultID, root: root)
        }
    }

    public func createCheckpoint(vaultID: UUID, message: String, scope: CheckpointScope? = nil) throws -> Checkpoint {
        try operation { root in try captureAndPublish(record(vaultID, root: root), message: message, scope: scope, root: root) }
    }

    public func checkpointPlan(vaultID: UUID, mode: CheckpointMode) throws -> CheckpointPlan {
        try operation { root in
            let vault = try record(vaultID, root: root)
            let source = try VaultFS.directory(sourceURL(vault.url))
            return try CheckpointScopePlanner.plan(source: source, mode: mode)
        }
    }

    public func changes(vaultID: UUID, from: UUID?, to: UUID) throws -> [FileChange] {
        try operation { root in
            _ = try record(vaultID, root: root)
            let versions = try history(vaultID, root: root)
            let current = try checkpoint(to, in: versions)
            let previous = try from.map { try checkpoint($0, in: versions) }
            let old = Dictionary(uniqueKeysWithValues: (previous?.entries ?? []).map { ($0.path, $0) })
            let new = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.path, $0) })
            return Set(old.keys).union(new.keys).sorted().compactMap { path in
                guard old[path] != new[path] else { return nil }
                return FileChange(path: path, kind: old[path] == nil ? .added : new[path] == nil ? .deleted : .modified,
                                  oldEntry: old[path], newEntry: new[path])
            }
        }
    }

    public func text(vaultID: UUID, checkpointID: UUID, path: String) throws -> String? {
        try operation { root in
            try VaultFS.relative(path)
            _ = try record(vaultID, root: root)
            let version = try checkpoint(checkpointID, in: history(vaultID, root: root))
            guard let entry = version.entries.first(where: { $0.path == path }), entry.kind != .directory,
                  entry.size <= 512 * 1024, let digest = entry.digest else { return nil }
            let objects = try VaultFS.childDirectory(root, "objects")
            let data = try VaultFS.read(objects, digest, maximum: 512 * 1024)
            guard VaultFS.hash(data) == digest, data.count == entry.size else { throw VaultStoreError.corrupt("file object does not match its manifest") }
            guard !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    public func restoreCopy(vaultID: UUID, checkpointID: UUID, destination: URL) throws -> VaultRecord {
        try operation { root in
            let state = try registry(root)
            _ = try record(vaultID, root: root)
            let version = try checkpoint(checkpointID, in: history(vaultID, root: root))
            let destination = try destinationURL(destination, state: state)
            let parent = try VaultFS.directory(destination.deletingLastPathComponent())
            let temporary = ".planisphere-restore-" + UUID().uuidString
            let stageURL = destination.deletingLastPathComponent().appendingPathComponent(temporary)
            guard mkdirat(parent.fd, temporary, 0o700) == 0 else { throw VaultFS.unavailable("Could not prepare the restored copy") }
            defer { try? FileManager.default.removeItem(at: stageURL) }
            let stage = try VaultFS.childDirectory(parent, temporary)
            try materialize(version, into: stage, root: root)
            let origin = RestorationOrigin(vaultID: vaultID, checkpointID: checkpointID)
            let restored = VaultRecord(name: try displayName(destination.lastPathComponent), path: destination.path, restoredFrom: origin)
            let first = Checkpoint(formatVersion: version.formatVersion, vaultID: restored.id, parentID: nil, message: "Restored copy", entries: version.entries, restoredFrom: origin, captureScope: version.captureScope)
            // Prepare recoverable history before exposing any new working folder.
            try publish(first, root: root)
            try VaultFS.publishDirectory(parent: parent, temporary: temporary, destination: destination.lastPathComponent)
            do {
                var updated = state
                updated.vaults.append(restored)
                try Self.write(updated, to: "registry.json", in: root, replace: true)
                return restored
            } catch {
                throw VaultStoreError.unavailable("The restored folder is complete at \(destination.path), but registration did not finish. Original files and history remain intact. Add the restored folder to continue. \(error.localizedDescription)")
            }
        }
    }

    public func exportVault(vaultID: UUID, destination: URL) throws -> URL {
        try operation { root in
            let state = try registry(root)
            let vault = try record(vaultID, root: root)
            let destination = try destinationURL(destination, state: state)
            // Saved history remains portable even when the working folder is unavailable.
            let versions = try history(vaultID, root: root)
            guard let current = versions.first else {
                throw VaultStoreError.invalid("Create a checkpoint before exporting. Export includes saved checkpoints, not unsaved working files.")
            }
            let parent = try VaultFS.directory(destination.deletingLastPathComponent())
            let temporary = ".planisphere-export-" + UUID().uuidString
            let stageURL = destination.deletingLastPathComponent().appendingPathComponent(temporary)
            guard mkdirat(parent.fd, temporary, 0o700) == 0 else { throw VaultFS.unavailable("Could not prepare the export") }
            defer { try? FileManager.default.removeItem(at: stageURL) }
            let stage = try VaultFS.childDirectory(parent, temporary)
            let files = try VaultFS.childDirectory(stage, "files", create: true)
            try materialize(current, into: files, root: root)
            let historyFolder = try VaultFS.childDirectory(stage, "history", create: true)
            try Self.write(ExportInfo(vault: vault, currentCheckpointID: current.id), to: "export.json", in: historyFolder, replace: false)
            let manifests = try VaultFS.childDirectory(historyFolder, "checkpoints", create: true)
            for version in versions { try Self.write(version, to: version.id.uuidString + ".json", in: manifests, replace: false) }
            let exportedObjects = try VaultFS.childDirectory(historyFolder, "objects", create: true)
            var copied: Set<String> = []
            for version in versions {
                for entry in version.entries where entry.kind != .directory {
                    guard let digest = entry.digest else { throw VaultStoreError.corrupt("missing object digest") }
                    if copied.insert(digest).inserted { try copyObject(entry, to: exportedObjects, name: digest, root: root) }
                }
            }
            try VaultFS.sync(exportedObjects.fd); try VaultFS.sync(manifests.fd)
            try VaultFS.sync(historyFolder.fd); try VaultFS.sync(stage.fd)
            try VaultFS.publishDirectory(parent: parent, temporary: temporary, destination: destination.lastPathComponent)
            return destination
        }
    }

    private func sourceURL(_ url: URL) throws -> URL {
        let directory = try VaultFS.directory(VaultFS.absolute(url))
        let source = try VaultFS.canonicalURL(directory)
        let root = try VaultFS.directory(rootURL)
        guard source.path != "/", !VaultFS.contains(source, rootURL), !VaultFS.contains(rootURL, source),
              try !VaultFS.containsDirectory(directory, root), try !VaultFS.containsDirectory(root, directory) else {
            throw VaultStoreError.invalid("The working vault and history store must be separate folders, outside one another.")
        }
        return source
    }

    private func destinationURL(_ url: URL, state: Registry) throws -> URL {
        let requested = try VaultFS.absolute(url)
        let parent = try VaultFS.directory(requested.deletingLastPathComponent())
        let destination = try VaultFS.canonicalURL(parent).appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        let root = try VaultFS.directory(rootURL)
        guard !VaultFS.contains(destination, rootURL), !VaultFS.contains(rootURL, destination),
              try !VaultFS.containsDirectory(root, parent) else {
            throw VaultStoreError.invalid("The destination and history store must be separate folders.")
        }
        for record in state.vaults {
            let existing = try? VaultFS.directory(record.url)
            let withinExisting = try existing.map { try VaultFS.containsDirectory($0, parent) } ?? false
            if VaultFS.contains(record.url, destination) || withinExisting {
                throw VaultStoreError.invalid("Choose a new folder outside every registered vault.")
            }
        }
        guard try VaultFS.entryInfo(parent, destination.lastPathComponent) == nil else {
            throw VaultStoreError.invalid("The destination already exists. Choose a new folder; nothing will be overwritten.")
        }
        return destination
    }

    private func displayName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 1024 else { throw VaultStoreError.invalid("Choose a nonempty vault name.") }
        return name
    }

    private func operation<T>(_ body: (VaultFS.Handle) throws -> T) throws -> T {
        let root = try VaultFS.directory(rootURL)
        return try Self.locked(root) { try body(root) }
    }

    private static func locked<T>(_ root: VaultFS.Handle, _ body: () throws -> T) throws -> T {
        let lock = try VaultFS.Handle(openat(root.fd, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600))
        guard (try VaultFS.info(lock).st_mode & S_IFMT) == S_IFREG else { throw VaultStoreError.corrupt("invalid store lock") }
        guard flock(lock.fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw VaultStoreError.busy }
            throw VaultFS.unavailable("Could not lock the history store")
        }
        defer { flock(lock.fd, LOCK_UN) }
        return try body()
    }

    private static func write<T: Codable>(_ payload: T, to name: String, in directory: VaultFS.Handle, replace: Bool) throws {
        let data = try VaultFormat.encode(payload)
        let envelope = Envelope(payload: payload, sha256: VaultFS.hash(data))
        let encoded = try VaultFormat.encode(envelope)
        guard encoded.count <= VaultFS.metadataLimit else { throw VaultStoreError.invalid("History metadata exceeds the current 64 MiB limit.") }
        try VaultFS.atomicData(encoded, parent: directory, name: name, replace: replace)
    }

    private static func read<T: Codable>(_ name: String, in directory: VaultFS.Handle) throws -> T {
        do {
            let envelope = try VaultFormat.decode(Envelope<T>.self, from: VaultFS.read(directory, name))
            guard VaultFS.hash(try VaultFormat.encode(envelope.payload)) == envelope.sha256 else {
                throw VaultStoreError.corrupt("metadata checksum mismatch")
            }
            return envelope.payload
        } catch let error as VaultStoreError { throw error }
        catch { throw VaultStoreError.corrupt("metadata could not be decoded") }
    }

    private static func validateRegistry(_ state: Registry) throws {
        guard state.formatVersion == 1, Set(state.vaults.map(\.id)).count == state.vaults.count,
              Set(state.vaults.map { VaultFS.portablePathKey($0.path) }).count == state.vaults.count else { throw VaultStoreError.corrupt("invalid registry version or duplicate vault identity") }
        for record in state.vaults {
            guard !record.name.isEmpty, record.path.hasPrefix("/"), record.createdAt.timeIntervalSince1970.isFinite,
                  try VaultFS.absolute(record.url).path == record.path else { throw VaultStoreError.corrupt("invalid vault record") }
        }
    }

    private func registry(_ root: VaultFS.Handle) throws -> Registry {
        let state: Registry = try Self.read("registry.json", in: root)
        try Self.validateRegistry(state)
        for record in state.vaults {
            guard !VaultFS.contains(record.url, rootURL), !VaultFS.contains(rootURL, record.url) else {
                throw VaultStoreError.corrupt("registry overlaps working files with their history")
            }
        }
        return state
    }

    private func record(_ id: UUID, root: VaultFS.Handle) throws -> VaultRecord {
        guard let record = try registry(root).vaults.first(where: { $0.id == id }) else { throw VaultStoreError.invalid("Vault not found.") }
        return record
    }

    private func vaultDirectory(_ id: UUID, root: VaultFS.Handle, create: Bool = false) throws -> VaultFS.Handle {
        let vaults = try VaultFS.childDirectory(root, "vaults")
        let existed = try VaultFS.entryInfo(vaults, id.uuidString) != nil
        let vault = try VaultFS.childDirectory(vaults, id.uuidString, create: create)
        if create {
            _ = try VaultFS.childDirectory(vault, "checkpoints", create: true)
            if !existed { try Self.write(Head(checkpointID: nil), to: "head.json", in: vault, replace: false) }
            guard try VaultFS.entryInfo(vault, "head.json") != nil else { throw VaultStoreError.corrupt("history head is missing") }
            try VaultFS.sync(vaults.fd)
        }
        return vault
    }

    private func validate(_ checkpoint: Checkpoint) throws {
        guard [1, 2].contains(checkpoint.formatVersion), checkpoint.createdAt.timeIntervalSince1970.isFinite,
              checkpoint.entries.count <= 250_000, checkpoint.parentID != checkpoint.id else {
            throw VaultStoreError.corrupt("invalid checkpoint header")
        }
        guard checkpoint.formatVersion == 2 || checkpoint.captureScope == nil else {
            throw VaultStoreError.corrupt("capture scope requires checkpoint format 2")
        }
        try checkpoint.captureScope?.validate()
        var paths: [String: FileEntry] = [:]
        var portablePaths: Set<String> = []
        var totalBytes: Int64 = 0
        for entry in checkpoint.entries {
            try VaultFS.relative(entry.path)
            guard checkpoint.captureScope?.excludes(entry.path, isDirectory: entry.kind == .directory, isSymbolicLink: entry.kind == .symbolicLink, isRegularFile: entry.kind == .file) != true else {
                throw VaultStoreError.corrupt("checkpoint includes a path excluded by its recorded scope")
            }
            guard paths[entry.path] == nil, portablePaths.insert(VaultFS.portablePathKey(entry.path)).inserted,
                  entry.size >= 0 else { throw VaultStoreError.corrupt("case/Unicode path collision or invalid size") }
            let (sum, overflow) = totalBytes.addingReportingOverflow(entry.size)
            guard !overflow else { throw VaultStoreError.corrupt("checkpoint byte count overflow") }
            totalBytes = sum
            if entry.kind == .directory {
                guard entry.digest == nil, entry.size == 0, !entry.executable else { throw VaultStoreError.corrupt("invalid directory entry") }
            } else {
                guard let digest = entry.digest, digest.count == 64,
                      digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw VaultStoreError.corrupt("invalid object digest") }
                if entry.kind == .symbolicLink {
                    guard checkpoint.formatVersion == 2, !entry.executable,
                          entry.size > 0, entry.size <= Int64(VaultFS.symbolicLinkLimit) else {
                        throw VaultStoreError.corrupt("invalid symbolic-link entry or format version")
                    }
                }
            }
            paths[entry.path] = entry
        }
        var requiredDirectories: Set<String> = []
        for path in paths.keys {
            let parts = path.split(separator: "/")
            if parts.count > 1 {
                for index in 1..<parts.count {
                    let parent = parts.prefix(index).joined(separator: "/")
                    guard paths[parent]?.kind == .directory else {
                        throw VaultStoreError.corrupt("missing or non-directory parent")
                    }
                    if paths[path]?.kind == .file { requiredDirectories.insert(parent) }
                }
            }
        }
        if checkpoint.captureScope?.mode == .markdownOnly {
            guard checkpoint.entries.allSatisfy({ $0.kind != .directory || requiredDirectories.contains($0.path) }) else {
                throw VaultStoreError.corrupt("Markdown Only checkpoint contains an unrelated directory")
            }
        }
    }

    private func history(_ id: UUID, root: VaultFS.Handle) throws -> [Checkpoint] {
        let vault = try vaultDirectory(id, root: root)
        guard try VaultFS.entryInfo(vault, "head.json") != nil else {
            throw VaultStoreError.corrupt("history head is missing")
        }
        let head: Head = try Self.read("head.json", in: vault)
        guard head.formatVersion == 1 else { throw VaultStoreError.corrupt("unsupported history head") }
        let manifests = try VaultFS.childDirectory(vault, "checkpoints")
        var next: UUID? = head.checkpointID
        var seen: Set<UUID> = []
        var objects: [String: Int64] = [:]
        var result: [Checkpoint] = []
        while let current = next {
            guard seen.insert(current).inserted else { throw VaultStoreError.corrupt("cyclic history") }
            let version: Checkpoint = try Self.read(current.uuidString + ".json", in: manifests)
            guard version.id == current, version.vaultID == id else { throw VaultStoreError.corrupt("history identity mismatch") }
            try validate(version)
            for entry in version.entries where entry.kind != .directory {
                let digest = entry.digest!
                if let size = objects[digest] {
                    guard size == entry.size else { throw VaultStoreError.corrupt("inconsistent object sizes") }
                } else {
                    try verifyObject(entry, root: root)
                    objects[digest] = entry.size
                }
                // An object shared with a regular file must still pass link-target validation.
                if entry.kind == .symbolicLink { _ = try symbolicLinkTarget(entry, root: root) }
            }
            result.append(version); next = version.parentID
        }
        return result
    }

    private func checkpoint(_ id: UUID, in history: [Checkpoint]) throws -> Checkpoint {
        guard let version = history.first(where: { $0.id == id }) else { throw VaultStoreError.invalid("Checkpoint not found in this vault's published history.") }
        return version
    }

    private func verifyObject(_ entry: FileEntry, root: VaultFS.Handle) throws {
        guard let digest = entry.digest else { throw VaultStoreError.corrupt("missing file object") }
        let objects = try VaultFS.childDirectory(root, "objects")
        let source = try VaultFS.Handle(openat(objects.fd, digest, O_RDONLY | O_NOFOLLOW | O_CLOEXEC))
        let result = try VaultFS.stream(source, limit: entry.size)
        guard result.digest == digest, result.size == entry.size else { throw VaultStoreError.corrupt("file object checksum mismatch") }
    }

    private func symbolicLinkTarget(_ entry: FileEntry, root: VaultFS.Handle) throws -> Data {
        guard entry.kind == .symbolicLink, let digest = entry.digest,
              entry.size > 0, entry.size <= Int64(VaultFS.symbolicLinkLimit) else {
            throw VaultStoreError.corrupt("invalid symbolic-link object")
        }
        let objects = try VaultFS.childDirectory(root, "objects")
        let data = try VaultFS.read(objects, digest, maximum: VaultFS.symbolicLinkLimit)
        guard Int64(data.count) == entry.size, VaultFS.hash(data) == digest else {
            throw VaultStoreError.corrupt("symbolic-link target does not match its manifest")
        }
        try VaultFS.validateSymbolicLinkTarget(data)
        return data
    }

    private func captureAndPublish(_ record: VaultRecord, message: String, scope: CheckpointScope?, root: VaultFS.Handle, expectedFiles: [String: String]? = nil, expectedEntries: [FileEntry]? = nil) throws -> Checkpoint {
        guard message.utf8.count <= 65536 else { throw VaultStoreError.invalid("Checkpoint message is too long.") }
        let previous = try history(record.id, root: root).first
        let source = try VaultFS.directory(sourceURL(record.url))
        try scope?.validate()
        try scope?.verifySource(source)
        let first = try inventory(source, root: root, persist: true, scope: scope)
        try captureValidationHook?()
        let secondSource = try VaultFS.directory(sourceURL(record.url))
        let second = try inventory(secondSource, root: root, persist: false, scope: scope)
        try scope?.verifySource(secondSource)
        guard first.entries == second.entries, first.stamps == second.stamps else { throw VaultStoreError.changedDuringCapture }
        if let expectedEntries, first.entries != expectedEntries {
            throw VaultStoreError.invalid("Vault content changed after text review. No checkpoint was published for this state.")
        }
        if let expectedFiles {
            guard Self.markdownFiles(first.entries) == expectedFiles else {
                throw VaultStoreError.invalid("Markdown changed after review. Review a fresh pruning plan; no checkpoint was published for this state.")
            }
        }
        let formatVersion = scope != nil || first.entries.contains(where: { $0.kind == .symbolicLink }) ? 2 : 1
        let version = Checkpoint(formatVersion: formatVersion, vaultID: record.id, parentID: previous?.id, message: message, entries: first.entries, restoredFrom: record.restoredFrom, captureScope: scope)
        try publish(version, root: root)
        return version
    }

    private func inventory(_ source: VaultFS.Handle, root: VaultFS.Handle, persist: Bool, scope: CheckpointScope?) throws -> Capture {
        let objects = try VaultFS.childDirectory(root, "objects")
        var entries: [FileEntry] = []
        var stamps: [String: VaultFS.Stamp] = [:]
        func walk(_ directory: VaultFS.Handle, prefix: String) throws {
            let before = try VaultFS.info(directory)
            stamps[prefix] = VaultFS.Stamp(before)
            for name in try VaultFS.names(directory) {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                try VaultFS.relative(path)
                guard let info = try VaultFS.entryInfo(directory, name) else { throw VaultStoreError.changedDuringCapture }
                let kind = info.st_mode & S_IFMT
                if scope?.excludes(path, isDirectory: kind == S_IFDIR, isSymbolicLink: kind == S_IFLNK, isRegularFile: kind == S_IFREG) == true { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = try VaultFS.childDirectory(directory, name)
                    guard VaultFS.Stamp(info) == VaultFS.Stamp(try VaultFS.info(child)) else { throw VaultStoreError.changedDuringCapture }
                    let previousCount = entries.count
                    if scope?.mode != .markdownOnly { entries.append(FileEntry(path: path, kind: .directory)) }
                    try walk(child, prefix: path)
                    if scope?.mode == .markdownOnly {
                        if entries.count > previousCount { entries.append(FileEntry(path: path, kind: .directory)) }
                        else { stamps.removeValue(forKey: path) }
                    }
                case S_IFREG:
                    let file = try VaultFS.Handle(openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
                    guard VaultFS.Stamp(info) == VaultFS.Stamp(try VaultFS.info(file)) else { throw VaultStoreError.changedDuringCapture }
                    let temporary = ".incoming-" + UUID().uuidString
                    var output: VaultFS.Handle?
                    if persist { output = try VaultFS.Handle(openat(objects.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)) }
                    defer { if persist { unlinkat(objects.fd, temporary, 0) } }
                    let streamed = try VaultFS.stream(file, destination: output?.fd)
                    guard VaultFS.Stamp(info) == VaultFS.Stamp(try VaultFS.info(file)), streamed.size == info.st_size else {
                        throw VaultStoreError.changedDuringCapture
                    }
                    if let output {
                        try VaultFS.sync(output.fd)
                        if try VaultFS.entryInfo(objects, streamed.digest) == nil {
                            guard renameatx_np(objects.fd, temporary, objects.fd, streamed.digest, UInt32(RENAME_EXCL)) == 0 else {
                                throw VaultFS.unavailable("Could not publish a file object")
                            }
                            try VaultFS.sync(objects.fd)
                        } else {
                            try verifyObject(FileEntry(path: path, kind: .file, digest: streamed.digest, size: streamed.size), root: root)
                        }
                    }
                    entries.append(FileEntry(path: path, kind: .file, digest: streamed.digest, size: streamed.size, executable: info.st_mode & 0o111 != 0))
                    stamps[path] = VaultFS.Stamp(info)
                case S_IFLNK:
                    let data = try VaultFS.readSymbolicLink(directory, name)
                    guard let after = try VaultFS.entryInfo(directory, name), VaultFS.Stamp(info) == VaultFS.Stamp(after) else {
                        throw VaultStoreError.changedDuringCapture
                    }
                    let digest = VaultFS.hash(data)
                    let entry = FileEntry(path: path, kind: .symbolicLink, digest: digest, size: Int64(data.count))
                    if persist {
                        if try VaultFS.entryInfo(objects, digest) == nil {
                            try VaultFS.atomicData(data, parent: objects, name: digest, replace: false)
                        } else { _ = try symbolicLinkTarget(entry, root: root) }
                    }
                    entries.append(entry)
                    stamps[path] = VaultFS.Stamp(info)
                default:
                    throw VaultStoreError.invalid("Special files such as sockets and pipes are unsupported: \(path)")
                }
                guard entries.count <= 250_000 else { throw VaultStoreError.invalid("This vault exceeds the current 250,000-entry limit.") }
            }
            guard VaultFS.Stamp(before) == VaultFS.Stamp(try VaultFS.info(directory)) else { throw VaultStoreError.changedDuringCapture }
        }
        try walk(source, prefix: "")
        return Capture(entries: entries.sorted { $0.path < $1.path }, stamps: stamps)
    }

    private func publish(_ version: Checkpoint, root: VaultFS.Handle) throws {
        try validate(version)
        let vault = try vaultDirectory(version.vaultID, root: root, create: true)
        let manifests = try VaultFS.childDirectory(vault, "checkpoints")
        try Self.write(version, to: version.id.uuidString + ".json", in: manifests, replace: false)
        try Self.write(Head(checkpointID: version.id), to: "head.json", in: vault, replace: true)
    }

    private func materialize(_ version: Checkpoint, into destination: VaultFS.Handle, root: VaultFS.Handle) throws {
        try validate(version)
        // Parent-before-child ordering; explicit directory entries retain empty folders.
        for entry in version.entries.filter({ $0.kind != .symbolicLink }).sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
            let components = entry.path.split(separator: "/").map(String.init)
            var parent = destination
            for component in components.dropLast() { parent = try VaultFS.childDirectory(parent, component) }
            let name = components.last!
            if entry.kind == .directory { _ = try VaultFS.childDirectory(parent, name, create: true) }
            else { try copyObject(entry, to: parent, name: name, root: root) }
        }
        // No regular content is written after links exist. Link targets may be absolute,
        // outside this folder, or broken; preserve the reference without following it.
        for entry in version.entries where entry.kind == .symbolicLink {
            let components = entry.path.split(separator: "/").map(String.init)
            var parent = destination
            for component in components.dropLast() { parent = try VaultFS.childDirectory(parent, component) }
            try VaultFS.createSymbolicLink(symbolicLinkTarget(entry, root: root), parent: parent, name: components.last!)
        }
        for entry in version.entries.filter({ $0.kind == .directory }).sorted(by: { $0.path.count > $1.path.count }) {
            var directory = destination
            for component in entry.path.split(separator: "/") { directory = try VaultFS.childDirectory(directory, String(component)) }
            try VaultFS.sync(directory.fd)
        }
        try VaultFS.sync(destination.fd)
    }

    private func copyObject(_ entry: FileEntry, to destination: VaultFS.Handle, name: String, root: VaultFS.Handle) throws {
        guard let digest = entry.digest else { throw VaultStoreError.corrupt("missing object digest") }
        let objects = try VaultFS.childDirectory(root, "objects")
        let source = try VaultFS.Handle(openat(objects.fd, digest, O_RDONLY | O_NOFOLLOW | O_CLOEXEC))
        let file = try VaultFS.Handle(openat(destination.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, entry.executable ? 0o700 : 0o600))
        let result = try VaultFS.stream(source, destination: file.fd, limit: entry.size)
        guard result.digest == digest, result.size == entry.size else { throw VaultStoreError.corrupt("file object checksum mismatch during copy") }
        try VaultFS.sync(file.fd)
    }
}

extension VaultStore {
    private struct MutationJournal: Codable {
        var formatVersion = 1
        let plan: MarkdownMutationPlan
        var receipt: MarkdownMutationReceipt
    }

    private static func markdownFiles(_ entries: [FileEntry]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == .file }.map { ($0.path, $0.digest!) })
    }

    private static func recoveryName(_ plan: MarkdownMutationPlan, _ index: Int) -> String {
        ".planisphere-recovery-" + plan.id.uuidString + "-" + String(index)
    }

    private static func recoveryPaths(_ plan: MarkdownMutationPlan) -> [String] {
        plan.changes.enumerated().map { index, change in
            let parent = URL(fileURLWithPath: plan.vaultPath).appendingPathComponent(change.path).deletingLastPathComponent()
            let folder = plan.textReview == nil ? parent : parent.appendingPathComponent(".planisphere-recovery")
            return folder.appendingPathComponent(recoveryName(plan, index)).path
        }
    }

    private static func expectedAfter(_ plan: MarkdownMutationPlan) -> [String: String] {
        var files = plan.expectedFiles
        for change in plan.changes { files[change.path] = change.after.map(VaultFS.hash) }
        return files
    }

    private static func expectedAfterEntries(_ plan: MarkdownMutationPlan) -> [FileEntry]? {
        guard let review = plan.textReview else { return nil }
        let changes = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.path, $0) })
        return review.entries.compactMap { entry in
            guard let change = changes[entry.path] else { return entry }
            guard let after = change.after else { return nil }
            return FileEntry(path: entry.path, kind: .file, digest: VaultFS.hash(after),
                             size: Int64(after.count), executable: entry.executable)
        }
    }

    /// The caller must show the exact plan and obtain local human approval first.
    /// This records local approval provenance, not an externally signed permission.
    public func applyMarkdownMutation(_ plan: MarkdownMutationPlan) throws -> MarkdownMutationReceipt {
        guard plan.textReview == nil else { throw VaultStoreError.invalid("Use the explicit text mutation API for this plan.") }
        return try applyReviewedMutation(plan)
    }

    /// Apply only the exact text repair already reviewed within the caller's authority.
    /// Journal format 2 requires a reader supporting text mutations; older readers fail closed.
    public func applyTextMutation(_ review: TextMutationPlan) throws -> TextMutationReceipt {
        guard review.plan.textReview != nil else { throw VaultStoreError.invalid("This is not a reviewed text mutation plan.") }
        return try applyReviewedMutation(review.plan)
    }

    private func applyReviewedMutation(_ plan: MarkdownMutationPlan) throws -> MarkdownMutationReceipt {
        try operation { root in
            try plan.validate()
            let vault = try record(plan.vaultID, root: root)
            guard vault.path == plan.vaultPath else { throw VaultStoreError.invalid("The reviewed plan belongs to a different vault path.") }
            let vaultFolder = try vaultDirectory(vault.id, root: root)
            let journals = try VaultFS.childDirectory(vaultFolder, "mutations", create: true)
            let journalName = plan.id.uuidString + ".json"
            if try VaultFS.entryInfo(journals, journalName) != nil {
                let previous: MutationJournal = try Self.read(journalName, in: journals)
                try validateJournal(previous, name: journalName, vault: vault, root: root)
                guard previous.plan == plan else { throw VaultStoreError.invalid("This operation ID is already bound to a different reviewed plan.") }
                if previous.receipt.status == .completed { return previous.receipt }
                throw VaultStoreError.invalid("This pruning operation was interrupted. Inspect its recovery checkpoint and files, then prepare a fresh review. It will not be replayed.")
            }
            // Validate all prior receipts before adding another mutation. Pending work
            // is never resumed automatically, and its originals remain available.
            let previousReceipts = try mutationReceipts(vault: vault, root: root)
            guard previousReceipts.allSatisfy({ $0.status == .completed || $0.recoveryAcknowledgedAt != nil }) else {
                throw VaultStoreError.invalid("Inspect and acknowledge the interrupted pruning recovery before reviewing another change. No source files were changed.")
            }
            let action = plan.textReview == nil ? "locally approved pruning" : "reviewed text repair"
            let before = try captureAndPublish(vault, message: "Before " + action, scope: plan.scope, root: root,
                                              expectedFiles: plan.expectedFiles, expectedEntries: plan.textReview?.entries)
            var journal = MutationJournal(formatVersion: plan.textReview == nil ? 1 : 2, plan: plan, receipt: MarkdownMutationReceipt(
                id: plan.id, vaultID: vault.id, planDigest: plan.digest, beforeCheckpointID: before.id,
                afterCheckpointID: nil, startedAt: Date(), finishedAt: nil, status: .pending, recoveryAcknowledgedAt: nil,
                changedPaths: plan.changes.map(\.path), appliedPaths: [], recoveryPaths: Self.recoveryPaths(plan), error: nil))
            // The immutable precheckpoint and durable pending receipt precede every
            // source write, including creation of replacement staging files.
            try Self.write(journal, to: journalName, in: journals, replace: false)
            do {
                try mutationStepHook?(-1, "journal")
                let source = try VaultFS.directory(sourceURL(vault.url))
                try plan.scope.verifySource(source)
                let checkedEntries = try inventory(source, root: root, persist: false, scope: plan.scope).entries
                guard Self.markdownFiles(checkedEntries) == plan.expectedFiles,
                      plan.textReview == nil || checkedEntries == plan.textReview?.entries else {
                    throw VaultStoreError.changedDuringCapture
                }
                for (index, change) in plan.changes.enumerated() {
                    let reopened = try VaultFS.directory(sourceURL(vault.url))
                    guard try VaultFS.sameDirectory(source, reopened) else { throw VaultStoreError.changedDuringCapture }
                    try plan.scope.verifySource(reopened)
                    let components = change.path.split(separator: "/").map(String.init)
                    var parent = reopened
                    for component in components.dropLast() { parent = try VaultFS.childDirectory(parent, component) }
                    let expectedParent = vault.url.appendingPathComponent(change.path).deletingLastPathComponent().path
                    guard try VaultFS.canonicalURL(parent).path == expectedParent else { throw VaultStoreError.changedDuringCapture }
                    let name = components.last!, recovery = Self.recoveryName(plan, index)
                    // Broad checkpoints exclude this hidden directory. Displaced bytes
                    // stay linked on the same filesystem without polluting the reviewed inventory.
                    let recoveryParent = plan.textReview == nil ? parent : try VaultFS.childDirectory(parent, ".planisphere-recovery", create: true)
                    guard try VaultFS.entryInfo(recoveryParent, recovery) == nil else {
                        throw VaultStoreError.invalid("A recovery path already exists. It has been preserved.")
                    }
                    let original = try Self.readMutationFile(parent, name)
                    guard original.data == change.before else { throw VaultStoreError.changedDuringCapture }
                    if let after = change.after {
                        try VaultFS.atomicData(after, parent: recoveryParent, name: recovery, replace: false)
                        let staged = try VaultFS.Handle(openat(recoveryParent.fd, recovery, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
                        guard fchmod(staged.fd, original.info.st_mode & 0o777) == 0 else { throw VaultFS.unavailable("Could not preserve note permissions") }
                        try VaultFS.sync(staged.fd)
                    }
                    try mutationStepHook?(index, "beforeExchange")
                    let checked = try Self.readMutationFile(parent, name)
                    guard checked.data == change.before, VaultFS.Stamp(checked.info) == VaultFS.Stamp(original.info),
                          try VaultFS.canonicalURL(parent).path == expectedParent else { throw VaultStoreError.changedDuringCapture }
                    try mutationStepHook?(index, "exchangeBoundary")
                    if change.after != nil {
                        guard renameatx_np(recoveryParent.fd, recovery, parent.fd, name, UInt32(RENAME_SWAP)) == 0 else {
                            throw VaultFS.unavailable("Could not exchange the reviewed note")
                        }
                    } else {
                        guard renameatx_np(parent.fd, name, recoveryParent.fd, recovery, UInt32(RENAME_EXCL)) == 0 else {
                            throw VaultFS.unavailable("Could not retain the retired note")
                        }
                    }
                    try VaultFS.sync(parent.fd)
                    if plan.textReview != nil { try VaultFS.sync(recoveryParent.fd) }
                    try mutationStepHook?(index, "afterExchange")
                    // Inspect what was actually displaced by the atomic operation.
                    // Its inode stays linked indefinitely, preserving late writes by
                    // editors with an old descriptor even after this check completes.
                    let displaced = try Self.readMutationFile(recoveryParent, recovery)
                    guard displaced.data == change.before,
                          displaced.info.st_dev == checked.info.st_dev,
                          displaced.info.st_ino == checked.info.st_ino else { throw VaultStoreError.changedDuringCapture }
                    journal.receipt.appliedPaths.append(change.path)
                    try Self.write(journal, to: journalName, in: journals, replace: true)
                }
                try mutationStepHook?(plan.changes.count, "beforeAfterCheckpoint")
                let after = try captureAndPublish(vault, message: "After " + action, scope: plan.scope,
                                                 root: root, expectedFiles: Self.expectedAfter(plan),
                                                 expectedEntries: Self.expectedAfterEntries(plan))
                journal.receipt.afterCheckpointID = after.id
                journal.receipt.status = .completed
                journal.receipt.finishedAt = Date()
                try Self.write(journal, to: journalName, in: journals, replace: true)
                let committed: MutationJournal = try Self.read(journalName, in: journals)
                return committed.receipt
            } catch {
                journal.receipt.status = .interrupted
                journal.receipt.error = String(error.localizedDescription.prefix(4096))
                // Failure to update leaves the earlier durable pending journal; the
                // next reader treats pending as interrupted, without changing notes.
                try? Self.write(journal, to: journalName, in: journals, replace: true)
                throw VaultStoreError.unavailable("Pruning stopped and may be partly applied. Recovery checkpoint \(before.id.uuidString) and retained recovery files are available. No automatic rollback was attempted. \(error.localizedDescription)")
            }
        }
    }

    /// A pending receipt found under the store lock means its writer ended before
    /// completion. Recovery is inspection/Restore Copy, never blind in-place replay.
    public func mutationReceipts(vaultID: UUID) throws -> [MarkdownMutationReceipt] {
        try operation { root in try mutationReceipts(vault: record(vaultID, root: root), root: root) }
    }

    /// Explicit local confirmation that recovery has been inspected. This does not
    /// claim completion, restore notes, delete evidence, or replay the old operation.
    public func acknowledgeMutationRecovery(vaultID: UUID, operationID: UUID) throws -> MarkdownMutationReceipt {
        try operation { root in
            let vault = try record(vaultID, root: root)
            _ = try mutationReceipts(vault: vault, root: root)
            let journals = try VaultFS.childDirectory(vaultDirectory(vault.id, root: root), "mutations")
            let name = operationID.uuidString + ".json"
            var journal: MutationJournal = try Self.read(name, in: journals)
            try validateJournal(journal, name: name, vault: vault, root: root)
            guard journal.receipt.status == .interrupted else {
                throw VaultStoreError.invalid("Only interrupted pruning recovery can be acknowledged.")
            }
            if journal.receipt.recoveryAcknowledgedAt == nil {
                journal.receipt.recoveryAcknowledgedAt = Date()
                try Self.write(journal, to: name, in: journals, replace: true)
            }
            let committed: MutationJournal = try Self.read(name, in: journals)
            return committed.receipt
        }
    }

    private func mutationReceipts(vault: VaultRecord, root: VaultFS.Handle) throws -> [MarkdownMutationReceipt] {
        let folder = try vaultDirectory(vault.id, root: root)
        guard try VaultFS.entryInfo(folder, "mutations") != nil else { return [] }
        let journals = try VaultFS.childDirectory(folder, "mutations")
        var result: [MarkdownMutationReceipt] = []
        for name in try VaultFS.names(journals) where !name.hasPrefix(".pending-") {
            var journal: MutationJournal = try Self.read(name, in: journals)
            try validateJournal(journal, name: name, vault: vault, root: root)
            if journal.receipt.status == .pending {
                journal.receipt.status = .interrupted
                journal.receipt.error = "The app stopped before pruning recorded completion. Inspect the recovery checkpoint and retained files before preparing another change."
                try Self.write(journal, to: name, in: journals, replace: true)
            }
            result.append(journal.receipt)
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    private func validateJournal(_ journal: MutationJournal, name: String, vault: VaultRecord, root: VaultFS.Handle) throws {
        try journal.plan.validate()
        let receipt = journal.receipt
        guard journal.formatVersion == (journal.plan.textReview == nil ? 1 : 2), name == journal.plan.id.uuidString + ".json",
              journal.plan.vaultID == vault.id, journal.plan.vaultPath == vault.path,
              receipt.id == journal.plan.id, receipt.vaultID == vault.id, receipt.planDigest == journal.plan.digest,
              receipt.startedAt.timeIntervalSince1970.isFinite,
              receipt.changedPaths == journal.plan.changes.map(\.path),
              receipt.recoveryPaths == Self.recoveryPaths(journal.plan),
              receipt.appliedPaths == Array(receipt.changedPaths.prefix(receipt.appliedPaths.count)) else {
            throw VaultStoreError.corrupt("invalid pruning recovery journal")
        }
        if let acknowledged = receipt.recoveryAcknowledgedAt {
            guard receipt.status == .interrupted, acknowledged.timeIntervalSince1970.isFinite else {
                throw VaultStoreError.corrupt("invalid recovery acknowledgment")
            }
        }
        let versions = try history(vault.id, root: root)
        let before = try checkpoint(receipt.beforeCheckpointID, in: versions)
        guard before.captureScope == journal.plan.scope, Self.markdownFiles(before.entries) == journal.plan.expectedFiles,
              journal.plan.textReview == nil || before.entries == journal.plan.textReview?.entries else {
            throw VaultStoreError.corrupt("pruning recovery checkpoint does not match the reviewed plan")
        }
        if let afterID = receipt.afterCheckpointID {
            let after = try checkpoint(afterID, in: versions)
            guard after.captureScope == journal.plan.scope, Self.markdownFiles(after.entries) == Self.expectedAfter(journal.plan),
                  journal.plan.textReview == nil || after.entries == Self.expectedAfterEntries(journal.plan) else {
                throw VaultStoreError.corrupt("pruning completion checkpoint does not match the plan")
            }
        }
        if receipt.status == .completed {
            guard receipt.afterCheckpointID != nil, receipt.finishedAt?.timeIntervalSince1970.isFinite == true,
                  receipt.appliedPaths == receipt.changedPaths else { throw VaultStoreError.corrupt("incomplete pruning completion receipt") }
        }
    }

    private static func readMutationFile(_ parent: VaultFS.Handle, _ name: String) throws -> (data: Data, info: stat) {
        let file = try VaultFS.Handle(openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        let before = try VaultFS.info(file)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= 8 * 1024 * 1024 else {
            throw VaultStoreError.invalid("A reviewed note is no longer a supported regular file.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw VaultFS.unavailable("Could not verify a reviewed note") }
            if count == 0 { break }
            guard data.count + count <= 8 * 1024 * 1024 else { throw VaultStoreError.changedDuringCapture }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard VaultFS.Stamp(before) == VaultFS.Stamp(try VaultFS.info(file)), data.count == before.st_size,
              let named = try VaultFS.entryInfo(parent, name), VaultFS.Stamp(named) == VaultFS.Stamp(before) else {
            throw VaultStoreError.changedDuringCapture
        }
        return (data, before)
    }
}
