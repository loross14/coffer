import Foundation
import PlanisphereConnection

/// Puts the console's Claude Code reporting hooks into the same settings file as the memory hooks, and takes them out again.
/// Everything else in the file (other hooks, permissions, model settings) is kept as it is.
enum ReportingHookInstaller {
    enum InstallError: Error, CustomStringConvertible, Equatable {
        case unsafePath(String), malformed(String)
        var description: String {
            switch self {
            case .unsafePath(let path): "Claude Code's settings path (\(path)) goes through a symbolic link, so Planisphere did not change it."
            case .malformed(let detail): "Claude Code's settings file could not be read as JSON (\(detail)). Fix the file, then try again."
            }
        }
    }
    /// What the settings file carries right now.
    struct Installed: Equatable {
        let events: [String]
        let key: String?
        /// Enough of the key to recognise it in the console's Keys list, never the key itself.
        var keyHint: String? { key.map { String($0.prefix(12)) + "…" } }
    }

    static func settingsURL(home: URL) -> URL { home.appendingPathComponent("settings.json") }

    private static func checked(_ home: URL) throws -> URL {
        let settings = settingsURL(home: home)
        var path = settings
        while path.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil { throw InstallError.unsafePath(path.path) }
            path = path.deletingLastPathComponent()
        }
        return settings
    }
    private static func read(_ settings: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settings.path) else { return [:] }
        let data = try Data(contentsOf: settings)
        guard !data.isEmpty else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InstallError.malformed("not an object") }
            return object
        } catch let error as InstallError { throw error } catch { throw InstallError.malformed(error.localizedDescription) }
    }
    private static func groups(_ hooks: [String: Any], _ event: String) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw InstallError.malformed("hooks.\(event) is not an array of hook groups") }
        return groups
    }
    private static func isReporting(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String).map(ReportingHooks.isReportingCommand) ?? false
    }
    /// The groups with Planisphere's reporting hooks taken out; a group that only carried ours disappears.
    private static func withoutReporting(_ groups: [[String: Any]]) -> (kept: [[String: Any]], removed: Int) {
        var removed = 0
        let kept: [[String: Any]] = groups.compactMap { group in
            guard let hooks = group["hooks"] as? [[String: Any]] else { return group }
            let others = hooks.filter { !isReporting($0) }
            removed += hooks.count - others.count
            if others.isEmpty && hooks.count > 0 { return nil }
            var copy = group; copy["hooks"] = others; return copy
        }
        return (kept, removed)
    }
    private static func write(_ object: [String: Any], to settings: URL, previous: Data?) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        guard data != previous else { return }
        let folder = settings.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let previous {
            let backup = folder.appendingPathComponent("settings.json.planisphere-backup-\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000))")
            try previous.write(to: backup, options: .atomic)
        }
        let temporary = folder.appendingPathComponent(".settings.json.planisphere-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(settings, withItemAt: temporary)
    }

    /// Which reporting hooks the file holds, or nil when it holds none.
    static func status(home: URL) throws -> Installed? {
        let settings = try checked(home)
        let hooks = try read(settings)["hooks"] as? [String: Any] ?? [:]
        var events: [String] = [], key: String?
        for event in hooks.keys.sorted() {
            for group in try groups(hooks, event) {
                for hook in group["hooks"] as? [[String: Any]] ?? [] where isReporting(hook) {
                    if !events.contains(event) { events.append(event) }
                    if key == nil, let command = hook["command"] as? String { key = ReportingHooks.key(in: command) }
                }
            }
        }
        return events.isEmpty ? nil : Installed(events: events, key: key)
    }

    /// Replaces any reporting hooks already there with `grant`'s, next to whatever else the file holds.
    @discardableResult
    static func install(_ grant: [String: [ReportingHookGroup]], home: URL) throws -> URL {
        let settings = try checked(home)
        let previous = FileManager.default.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
        var object = try read(settings)
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        if object["hooks"] != nil, object["hooks"] as? [String: Any] == nil { throw InstallError.malformed("hooks is not an object") }
        for event in hooks.keys { hooks[event] = try withoutReporting(try groups(hooks, event)).kept }
        for (event, incoming) in grant {
            let added: [[String: Any]] = incoming.map { group in
                var entry: [String: Any] = ["hooks": group.hooks.map { ["type": $0.type, "command": $0.command] as [String: Any] }]
                if let matcher = group.matcher { entry["matcher"] = matcher }
                return entry
            }
            hooks[event] = (try groups(hooks, event)) + added
        }
        object["hooks"] = hooks
        try write(object, to: settings, previous: previous)
        return settings
    }

    /// Takes Planisphere's reporting hooks out and leaves the rest. Returns how many hooks went.
    @discardableResult
    static func remove(home: URL) throws -> Int {
        let settings = try checked(home)
        guard FileManager.default.fileExists(atPath: settings.path) else { return 0 }
        let previous = try Data(contentsOf: settings)
        var object = try read(settings)
        guard var hooks = object["hooks"] as? [String: Any] else { return 0 }
        var removed = 0
        for event in hooks.keys {
            let result = withoutReporting(try groups(hooks, event))
            removed += result.removed
            if result.kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = result.kept }
        }
        guard removed > 0 else { return 0 }
        if hooks.isEmpty { object.removeValue(forKey: "hooks") } else { object["hooks"] = hooks }
        try write(object, to: settings, previous: previous)
        return removed
    }
}
