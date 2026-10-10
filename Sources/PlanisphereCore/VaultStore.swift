import Foundation
import Darwin

/// Local, explicit version history. No networking, encryption-in-place or source
/// rewriting occurs. The OS lock also serializes separate application processes.
public actor VaultStore {
    public nonisolated let rootURL: URL
    // Deterministic fault injection for verifying concurrent-editor rejection.
    // Internal only; application and managed adapters cannot install this hook.
    private var captureValidationHook: (@Sendable () throws -> Void)?
    internal func setCaptureValidationHook(_ hook: (@Sendable () throws -> Void)?) { captureValidationHook = hook }

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

    public func createCheckpoint(vaultID: UUID, message: String) throws -> Checkpoint {
        try operation { root in try captureAndPublish(record(vaultID, root: root), message: message, root: root) }
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
            guard let entry = version.entries.first(where: { $0.path == path }), entry.kind == .file,
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
            let first = Checkpoint(vaultID: restored.id, parentID: nil, message: "Restored copy", entries: version.entries, restoredFrom: origin)
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
                for entry in version.entries where entry.kind == .file {
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
        guard checkpoint.formatVersion == 1, checkpoint.createdAt.timeIntervalSince1970.isFinite,
              checkpoint.entries.count <= 250_000, checkpoint.parentID != checkpoint.id else {
            throw VaultStoreError.corrupt("invalid checkpoint header")
        }
        var paths: [String: FileEntry] = [:]
        var portablePaths: Set<String> = []
        var totalBytes: Int64 = 0
        for entry in checkpoint.entries {
            try VaultFS.relative(entry.path)
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
            }
            paths[entry.path] = entry
        }
        for path in paths.keys {
            let parts = path.split(separator: "/")
            if parts.count > 1 {
                for index in 1..<parts.count {
                    guard paths[parts.prefix(index).joined(separator: "/")]?.kind == .directory else {
                        throw VaultStoreError.corrupt("missing or non-directory parent")
                    }
                }
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
            for entry in version.entries where entry.kind == .file {
                let digest = entry.digest!
                if let size = objects[digest] {
                    guard size == entry.size else { throw VaultStoreError.corrupt("inconsistent object sizes") }
                } else {
                    try verifyObject(entry, root: root)
                    objects[digest] = entry.size
                }
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

    private func captureAndPublish(_ record: VaultRecord, message: String, root: VaultFS.Handle) throws -> Checkpoint {
        guard message.utf8.count <= 65536 else { throw VaultStoreError.invalid("Checkpoint message is too long.") }
        let previous = try history(record.id, root: root).first
        let source = try VaultFS.directory(sourceURL(record.url))
        let first = try inventory(source, root: root, persist: true)
        try captureValidationHook?()
        let secondSource = try VaultFS.directory(sourceURL(record.url))
        let second = try inventory(secondSource, root: root, persist: false)
        guard first.entries == second.entries, first.stamps == second.stamps else { throw VaultStoreError.changedDuringCapture }
        let version = Checkpoint(vaultID: record.id, parentID: previous?.id, message: message, entries: first.entries, restoredFrom: record.restoredFrom)
        try publish(version, root: root)
        return version
    }

    private func inventory(_ source: VaultFS.Handle, root: VaultFS.Handle, persist: Bool) throws -> Capture {
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
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = try VaultFS.childDirectory(directory, name)
                    guard VaultFS.Stamp(info) == VaultFS.Stamp(try VaultFS.info(child)) else { throw VaultStoreError.changedDuringCapture }
                    entries.append(FileEntry(path: path, kind: .directory))
                    try walk(child, prefix: path)
                case S_IFREG:
                    let file = try VaultFS.Handle(openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC))
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
                default:
                    throw VaultStoreError.invalid("Symbolic links and special files are unsupported: \(path)")
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
        for entry in version.entries.sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
            let components = entry.path.split(separator: "/").map(String.init)
            var parent = destination
            for component in components.dropLast() { parent = try VaultFS.childDirectory(parent, component) }
            let name = components.last!
            if entry.kind == .directory { _ = try VaultFS.childDirectory(parent, name, create: true) }
            else { try copyObject(entry, to: parent, name: name, root: root) }
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
