import Foundation

/// What `planisphere_memory_setup.py --status` found for one agent app: the install state, the one
/// sentence that says what would stop the hooks from running, and the last recorded hook run.
struct AgentHostReport: Equatable, Sendable {
    struct LastRun: Equatable, Sendable {
        var at: Date?
        var action: String?
        var exitCode: Int?
        var app: String?
        var problem: String?
        var stderr: String?
    }

    /// The local vault reader Connect gave this agent: the vaults it can read and what would stop it.
    struct VaultReader: Equatable, Sendable {
        var vaults: [String]
        var command: String?
        var link: String?
        var problem: String?
        var lastRun: LastRun?

        /// "Vault reader: 2 vaults (Notes, Work) · last read 3 min ago" or "Vault reader: no vaults opened yet".
        func line(now: Date = Date()) -> String {
            var text = "Vault reader: "
            switch vaults.count {
            case 0: text += "no vaults opened yet"
            case 1: text += "1 vault (\(vaults[0]))"
            default: text += "\(vaults.count) vaults (\(vaults.joined(separator: ", ")))"
            }
            if let run = lastRun, let at = run.at {
                text += " · last read " + AgentHostReport.relative(at, now: now)
                if let code = run.exitCode, code != 0 { text += " failed (exit \(code))" }
            }
            return text
        }
    }

    var status: String
    var health: String?
    var problem: String?
    var app: String?
    var lastRun: LastRun?
    var vaultReader: VaultReader?

    static let unknown = AgentHostReport(status: "unknown")

    init(status: String, health: String? = nil, problem: String? = nil, app: String? = nil, lastRun: LastRun? = nil,
         vaultReader: VaultReader? = nil) {
        self.status = status; self.health = health; self.problem = problem; self.app = app; self.lastRun = lastRun
        self.vaultReader = vaultReader
    }

    init(json: [String: Any]) {
        status = json["status"] as? String ?? "unknown"
        health = json["health"] as? String
        problem = (json["problem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        app = json["app"] as? String
        lastRun = (json["last_run"] as? [String: Any]).map(Self.run)
        if let reader = json["vault_reader"] as? [String: Any] {
            let routes = reader["routes"] as? [[String: Any]] ?? []
            vaultReader = VaultReader(vaults: routes.compactMap { $0["vault"] as? String }, command: reader["command"] as? String,
                                      link: reader["link"] as? String,
                                      problem: (reader["problem"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                      lastRun: (reader["last_run"] as? [String: Any]).map(Self.run))
        }
    }

    private static func run(_ run: [String: Any]) -> LastRun {
        LastRun(at: (run["at"] as? String).flatMap(Self.parse), action: run["action"] as? String,
                exitCode: run["exit_code"] as? Int, app: run["app"] as? String,
                problem: run["problem"] as? String, stderr: run["stderr"] as? String)
    }

    /// Installed, but the hooks would not run as they stand.
    var broken: Bool { problem != nil }

    /// "Last hook run 3 min ago: exit 127 — sh: …: No such file or directory", or nil when none is recorded.
    func lastRunLine(now: Date = Date()) -> String? {
        guard let run = lastRun else { return nil }
        var line = "Last hook run"
        if let at = run.at { line += " " + Self.relative(at, now: now) }
        if run.problem == "app_missing" { return line + ": the Planisphere app was not found" }
        guard let code = run.exitCode else { return line }
        line += code == 0 ? ": ran (exit 0)" : ": failed (exit \(code))"
        if code != 0, let tail = run.stderr?.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            line += " — " + String(tail.prefix(160))
        }
        return line
    }

    private static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }
}
