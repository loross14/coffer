import CoreServices
import Foundation

/// Reports that files inside a vault changed on disk (an import, a checkpoint restore,
/// an agent writing notes) so views can refresh themselves instead of waiting for Reload.
///
/// One FSEvents stream per vault, delivered on a private queue, coalesced: a burst of
/// thousands of writes becomes one `onChange` after the vault has been quiet for `quiet`.
/// Hidden folders (`.obsidian`, `.git`, `.planisphere-recovery`, …) never count as changes,
/// so an editor rewriting its workspace file does not reload the graph.
public final class VaultChangeWatcher: @unchecked Sendable {
    public let root: URL
    private let quiet: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "ooo.planisphere.vault-watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let rootPaths: [String]

    /// - Parameters:
    ///   - root: the vault folder to watch, recursively.
    ///   - quiet: seconds without further changes before `onChange` fires. Keep this above the
    ///     FSEvents latency so one import is one refresh.
    ///   - onChange: called on a private queue after each quiet period that followed a change.
    public init(root: URL, quiet: TimeInterval = 1.5, onChange: @escaping @Sendable () -> Void) {
        self.root = root
        self.quiet = quiet
        self.onChange = onChange
        // FSEvents reports real paths (/private/tmp/…); Foundation shortens them (/tmp/…). Keep both.
        var roots: Set<String> = [root.path, root.standardizedFileURL.path]
        if let real = realpath(root.path, nil) { roots.insert(String(cString: real)); free(real) }
        rootPaths = roots.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
    }

    deinit { stop() }

    /// Starts the stream. Returns false when FSEvents refused the folder; the manual
    /// Reload still works in that case.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, Self.callback, &context, [root.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created); return false
        }
        stream = created
        return true
    }

    public func stop() {
        queue.sync {
            pending?.cancel(); pending = nil
            guard let stream else { return }
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Whether a changed path counts as a vault change: a file or folder inside the root, not under
    /// a hidden folder. The root folder's own entry changes with every child, so it never counts
    /// by itself; the child that changed is reported too.
    public static func isRelevant(_ path: String, roots: [String]) -> Bool {
        if roots.contains(path) { return false }
        guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return true }
        let relative = path.dropFirst(root.count).split(separator: "/")
        return !relative.contains { $0.hasPrefix(".") }
    }

    private func noteChanges(_ paths: [String]) {
        guard paths.contains(where: { Self.isRelevant($0, roots: rootPaths) }) else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + quiet, execute: item)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info, let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
        let watcher = Unmanaged<VaultChangeWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.noteChanges(Array(paths.prefix(count)))
    }
}
