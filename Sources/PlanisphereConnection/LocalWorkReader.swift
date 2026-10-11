import CryptoKit
import Darwin
import Foundation

public struct LocalPrompt: Sendable, Identifiable {
    public let id: String
    public let session: String
    public let turn: String
    public let agent: String
    public let project: String
    public let prompt: String
    public let responses: [String]
    public let observedAt: Date
}
public struct LocalHook: Sendable, Identifiable {
    public let id: String
    public let agent: String
    public let scope: String
    public let event: String
    public let purpose: String
    public let version: String?
    public let disabled: Bool
    public let configurationPath: String
}
public struct LocalWork: Sendable {
    public var prompts: [LocalPrompt] = []
    public var hooks: [LocalHook] = []
    public var notices: [String] = []
    public init() {}
}

/// Read-only views of Planisphere's existing local capture contract and host hook
/// configuration. Never executes a hook, reads a token, uploads text or changes retention.
public struct LocalWorkReader: Sendable {
    public let home: URL
    public init(home: URL? = nil) {
        #if DEBUG
        let fixture = ProcessInfo.processInfo.environment["PLANISPHERE_ACTIVITY_FIXTURE_HOME"].map { URL(fileURLWithPath: $0) }
        self.home = home ?? fixture ?? FileManager.default.homeDirectoryForCurrentUser
        #else
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        #endif
    }

    public static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func hasNoLinks(_ path: String) -> Bool {
        var component = path
        while component != "/" && !component.isEmpty {
            var info = stat()
            guard lstat(component, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return false }
            component = (component as NSString).deletingLastPathComponent
        }
        return true
    }

    private func bytes(_ url: URL, privateOnly: Bool, maximum: Int) throws -> Data {
        guard Self.hasNoLinks(url.path) else { throw CocoaError(.fileReadNoPermission) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= maximum,
              !privateOnly || info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    private func children(_ url: URL) -> [URL] {
        guard Self.hasNoLinks(url.path) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func load(project: URL?, now: Date = Date()) -> LocalWork {
        var result = LocalWork()
        let projectPath = project.map(Self.canonicalPath)
        var budget = 64 * 1024 * 1024
        var candidates: [(URL, String)] = []
        for host in ["codex", "claude"] {
            let root = home.appendingPathComponent(".local/state/planisphere/" + host)
            let connections = children(root)
            if connections.count > 100 { result.notices.append("Only the first 100 local connection folders were inspected.") }
            for connection in connections.prefix(100) {
                let files = children(connection.appendingPathComponent("conversation-memory"))
                candidates += files.filter { $0.pathExtension == "json" }.map { ($0, host) }
            }
        }
        candidates.sort { lhs, rhs in
            let a = try? lhs.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let b = try? rhs.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (a ?? .distantPast) > (b ?? .distantPast)
        }
        if candidates.count > 512 { result.notices.append("Showing a bounded snapshot of the 512 newest capture files.") }
        var rejected = 0
        for (file, host) in candidates.prefix(512) {
            guard budget > 0 else { result.notices.append("The local read limit was reached. Some captures were not inspected."); break }
            do {
                let data = try bytes(file, privateOnly: true, maximum: min(budget, 5 * 1024 * 1024))
                budget -= data.count
                let capture = try JSONDecoder().decode(Capture.self, from: data)
                guard capture.version == 1, capture.host == host,
                      capture.cwd.hasPrefix("/"), capture.messages.count <= 128 else { rejected += 1; continue }
                guard let projectPath, capture.cwd == projectPath else { continue }
                let sequence = capture.messages.map(\.sequence)
                guard sequence == sequence.sorted(), Set(sequence).count == sequence.count else { rejected += 1; continue }
                let messages = capture.messages.filter { message in
                    ["user", "assistant"].contains(message.role) && message.content.unicodeScalars.count == message.characters &&
                    message.characters <= 8000 && message.sha256 == SHA256.hash(data: Data(message.content.utf8)).map { String(format: "%02x", $0) }.joined() &&
                    (0..<86400).contains(now.timeIntervalSince1970 - message.observed_at)
                }
                let groups = Dictionary(grouping: messages, by: \.turn_id)
                for (turn, group) in groups {
                    guard let prompt = group.first(where: { $0.role == "user" }) else { continue }
                    result.prompts.append(LocalPrompt(id: [host, capture.session_id, turn].joined(separator: ":"),
                        session: capture.session_id, turn: turn, agent: host, project: capture.cwd,
                        prompt: prompt.content, responses: group.filter { $0.role == "assistant" }.map(\.content),
                        observedAt: Date(timeIntervalSince1970: prompt.observed_at)))
                }
            } catch { rejected += 1 }
        }
        var seen = Set<String>()
        result.prompts = result.prompts.sorted { $0.observedAt > $1.observedAt }.filter { seen.insert($0.id).inserted }
        if rejected > 0 { result.notices.append("\(rejected) local capture files could not be safely read.") }
        if project == nil { result.notices.append("Select a local vault to see captured prompts for that folder.") }
        result.notices.append("Local captures cover up to 24 hours and may omit or shorten messages. Tools, changed files, task outcomes and usage are not included in this source.")
        for (host, relative) in [("Codex", ".codex/hooks.json"), ("Claude Code", ".claude/settings.json"), ("Claude Code", ".claude/settings.local.json")] {
            let paths: [(URL, String)] = [(home.appendingPathComponent(relative), "All projects")] +
                (project.map { [($0.appendingPathComponent(relative), "Selected project")] } ?? [])
            for (file, scope) in paths {
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                do {
                    let data = try bytes(file, privateOnly: false, maximum: 2 * 1024 * 1024)
                    result.hooks += try Self.hooks(data: data, host: host, scope: scope, path: file.path)
                } catch { result.notices.append("Could not read \(host) hook settings for \(scope.lowercased()).") }
            }
        }
        return result
    }

    public static func hooks(data: Data, host: String, scope: String, path: String) throws -> [LocalHook] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["hooks"] as? [String: Any] else { return [] }
        let disabled = object["disableAllHooks"] as? Bool == true || object["enabled"] as? Bool == false
        var result: [LocalHook] = []
        for event in events.keys.sorted() {
            guard let groups = events[event] as? [[String: Any]] else { continue }
            for (g, group) in groups.prefix(100).enumerated() {
                for (h, hook) in ((group["hooks"] as? [[String: Any]]) ?? []).prefix(100).enumerated() {
                    guard let command = hook["command"] as? String, command.count <= 32000,
                          command.localizedCaseInsensitiveContains("planisphere") else { continue }
                    let purpose = command.contains("planisphere_usage") ? "Usage collection" :
                        command.contains("shared_feedback") ? "Task continuity" :
                        command.contains("response") ? "Context and response checks" : "Activity capture"
                    let version = command.range(of: "/[a-f0-9]{64}/", options: .regularExpression).map { String(command[$0].dropFirst().dropLast()) }
                    result.append(LocalHook(id: "\(path):\(event):\(g):\(h)", agent: host, scope: scope,
                        event: String(event.prefix(120)), purpose: purpose, version: version,
                        disabled: disabled || hook["enabled"] as? Bool == false,
                        configurationPath: path))
                }
            }
        }
        return result
    }
}

private struct Capture: Decodable {
    let version: Int
    let host: String
    let session_id: String
    let cwd: String
    let messages: [Message]
    struct Message: Decodable {
        let sequence: Int
        let turn_id: String
        let role: String
        let content: String
        let characters: Int
        let sha256: String
        let observed_at: Double
    }
}
