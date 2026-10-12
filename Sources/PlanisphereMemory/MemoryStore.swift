import Foundation
import Darwin

/// Single-profile local memory store. Instances are used serially; processes share a file lock.
public final class MemoryStore {
    private let directory: PrivateDirectory
    private let db: Database
    private let profile: String
    public var failurePoint: ((String) -> Void)?

    public init(directory url: URL, profile: String) throws {
        _ = try field(["profile": profile], "profile")
        let directory = try PrivateDirectory(url)
        self.directory = directory
        self.profile = profile
        db = try directory.locked {
            let fd = openat(directory.fd, "memory.sqlite3", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
            try require(fd >= 0, "Unsafe database file")
            defer { close(fd) }
            var info = stat()
            try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == getuid(), "Unsafe database identity")
            let db = try Database(path: directory.path + "/memory.sqlite3")
            let version = try db.rows("PRAGMA user_version").first?["user_version"] ?? "0"
            try require(["0", "1", "2"].contains(version), "Unsupported memory schema")
            try db.transaction {
                for sql in Self.schema { try db.exec(sql) }
                if let stored = try db.rows("SELECT value FROM metadata WHERE key='profile'").first?["value"] {
                    try require(stored == profile, "Profile mismatch")
                } else { try db.exec("INSERT INTO metadata VALUES ('profile',?)", [profile]) }
                if version != "2" { try db.exec("ALTER TABLE records ADD COLUMN scope TEXT NOT NULL DEFAULT 'personal'") }
                try db.exec("PRAGMA user_version=2")
            }
            return db
        }
    }

    private static let schema = [
        "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,kind TEXT NOT NULL,body TEXT NOT NULL,attribution TEXT NOT NULL,event_id TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY,record_id TEXT NOT NULL,source TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS revisions(record_id TEXT NOT NULL,revision INTEGER NOT NULL,body TEXT NOT NULL,attribution TEXT NOT NULL,event_id TEXT NOT NULL,PRIMARY KEY(record_id,revision))",
        "CREATE TABLE IF NOT EXISTS projections(record_id TEXT NOT NULL,revision INTEGER NOT NULL,path TEXT PRIMARY KEY,hash TEXT NOT NULL,phase TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS tombstones(record_id TEXT PRIMARY KEY,phase TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS retired_events(event_id TEXT PRIMARY KEY)",
        "CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,digest TEXT NOT NULL,result TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS bindings(owner_id TEXT PRIMARY KEY,host_id TEXT NOT NULL,project_id TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS task_refs(id TEXT PRIMARY KEY,owner_id TEXT NOT NULL REFERENCES bindings(owner_id),task_id TEXT NOT NULL,source_revision INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS bundles(id TEXT PRIMARY KEY,question TEXT NOT NULL,declaration_event TEXT NOT NULL,members TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,epoch TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS offers(id TEXT PRIMARY KEY,bundle_id TEXT NOT NULL,session_id TEXT NOT NULL,epoch TEXT NOT NULL,signature TEXT NOT NULL,members TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS delivered(bundle_id TEXT NOT NULL,session_id TEXT NOT NULL,epoch TEXT NOT NULL,record_id TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(bundle_id,session_id,epoch,record_id))"
    ]

    public func handle(_ request: [String: Any]) throws -> [String: Any] {
        try require(json(request).count <= 65_536, "Request exceeds memory limit")
        try require(field(request, "profile") == profile, "Profile mismatch")
        return try directory.locked {
            _ = try recover()
            let action = try field(request, "action")
            switch action {
            case "bootstrap", "status", "recover": return try status()
            case "configure":
                guard let enabled = request["enabled"] as? Bool else { throw MemoryError.rejected("enabled is required") }
                try db.exec("INSERT OR REPLACE INTO metadata VALUES ('enabled',?)", [enabled ? "1" : "0"])
                return try status()
            case "inspect": return try scopedRecord(request)
            case "resume": return try resume(request)
            case "session":
                let session = try field(request, "session_id"), epoch = token()
                try db.transaction {
                    try db.exec("INSERT OR REPLACE INTO sessions VALUES (?,?)", [session, epoch])
                    try db.exec("DELETE FROM offers WHERE session_id=?", [session])
                    try db.exec("DELETE FROM delivered WHERE session_id=?", [session])
                }
                return ["session_id": session, "epoch": epoch]
            case "offer": return try offer(request)
            case "ack": return try acknowledge(request)
            case "commit", "bind_owner", "reference_task", "forget_reference", "bundle", "forget":
                let operation = try field(request, "operation_id"), hash = digest(try json(request))
                let receipt: [String: Any] = try db.transaction {
                    if let old = try db.rows("SELECT * FROM operations WHERE id=?", [operation]).first {
                        try require(old["digest"] == hash, "Operation identity reused with different content")
                        return try object(Data(old["result"]!.utf8))
                    }
                    try require(try db.rows("SELECT id FROM operations LIMIT 10001").count < 10000, "Memory operation capacity reached")
                    let result = try mutate(action, request)
                    try db.exec("INSERT INTO operations VALUES (?,?,?)", [operation, hash, String(decoding: try json(result), as: UTF8.self)])
                    return result
                }
                failurePoint?(action == "forget" ? "forget_committed" : "committed")
                let gaps = try recover()
                var result = receipt
                result["recovery_gaps"] = gaps
                if action == "forget" {
                    result["deletion_state"] = try db.rows("SELECT phase FROM tombstones WHERE record_id=?", [try field(request, "record_id")]).first?["phase"] ?? "unknown"
                }
                return result
            default: throw MemoryError.rejected("Unsupported action")
            }
        }
    }

    private func mutate(_ action: String, _ r: [String: Any]) throws -> [String: Any] {
        if ["commit", "bind_owner", "reference_task", "bundle"].contains(action) {
            try require(try status()["enabled"] as? Bool == true, "Memory capture is paused")
        }
        switch action {
        case "commit":
            let scope = try field(r.merging(["scope": r["scope"] ?? "personal"]) { _, v in v }, "scope")
            let id = try field(r, "record_id"), event = try field(r, "event_id"), body = try field(r, "body", maximum: 8192)
            let source = try field(r, "source_excerpt", maximum: 4096), kind = try field(r, "kind"), attribution = try field(r, "attribution")
            try require(["decision", "correction", "preference", "outcome", "claim", "qualification"].contains(kind), "Unsupported record kind; tasks have a separate owner")
            try require(["human_statement", "host_observation", "agent_interpretation"].contains(attribution), "Invalid attribution")
            try require(try db.rows("SELECT record_id FROM tombstones WHERE record_id=?", [id]).isEmpty, "Record was forgotten")
            try require(try db.rows("SELECT event_id FROM retired_events WHERE event_id=?", [event]).isEmpty, "Event was retired by deletion")
            try require(try db.rows("SELECT id FROM events WHERE id=?", [event]).isEmpty, "Source event already used; replay original operation instead")
            let old = try db.rows("SELECT revision,scope FROM records WHERE id=?", [id]).first
            try require(old == nil || old?["scope"] == scope, "Record scope mismatch")
            let expected = try integer(r, "expected_revision")
            try require(Int(old?["revision"] ?? "0") == expected, "Stale record revision")
            let revision = expected + 1
            try db.exec("INSERT INTO events VALUES (?,?,?)", [event, id, source])
            try db.exec("INSERT OR REPLACE INTO records VALUES (?,?,?,?,?,?,?)", [id, String(revision), kind, body, attribution, event, scope])
            try db.exec("INSERT INTO revisions VALUES (?,?,?,?,?)", [id, String(revision), body, attribution, event])
            let bytes = try projection(id: id, revision: revision, body: body, attribution: attribution, event: event)
            let name = digest(Data(id.utf8)) + "-\(revision).md"
            try db.exec("INSERT INTO projections VALUES (?,?,?,?, 'pending')", [id, String(revision), name, digest(bytes)])
            return ["record_id": id, "accepted_revision": revision]
        case "bind_owner":
            let owner = try field(r, "owner_id"), host = try field(r, "host_id"), project = try field(r, "project_id")
            if let old = try db.rows("SELECT * FROM bindings WHERE owner_id=?", [owner]).first {
                try require(old["host_id"] == host && old["project_id"] == project, "Owner binding conflict")
            } else { try db.exec("INSERT INTO bindings VALUES (?,?,?)", [owner, host, project]) }
            return ["owner_id": owner, "status": "bound", "basis": "explicit adapter declaration; not inferred from path or title"]
        case "reference_task":
            let id = try field(r, "reference_id"), owner = try field(r, "owner_id"), task = try field(r, "task_id")
            let version = try integer(r, "source_revision", minimum: 1)
            try require(!(try db.rows("SELECT owner_id FROM bindings WHERE owner_id=?", [owner])).isEmpty, "Unbound task owner")
            if let old = try db.rows("SELECT * FROM task_refs WHERE id=?", [id]).first {
                try require(old["owner_id"] == owner && old["task_id"] == task, "Task reference identity conflict")
                try require(version >= Int(old["source_revision"]!)!, "Stale task reference")
            }
            try db.exec("INSERT OR REPLACE INTO task_refs VALUES (?,?,?,?)", [id, owner, task, String(version)])
            return ["reference_id": id, "source_revision": version, "task_authority": "bound owner"]
        case "forget_reference":
            let id = try field(r, "reference_id")
            try db.exec("DELETE FROM task_refs WHERE id=?", [id])
            return ["reference_id": id, "reference_removed": true, "source_deleted": false, "source_deletion": "request from the bound task owner"]
        case "bundle":
            let id = try field(r, "bundle_id"), question = try field(r, "question", maximum: 1000), event = try field(r, "declaration_event")
            guard let members = r["all_of"] as? [[String: Any]] else { throw MemoryError.rejected("all_of is required") }
            try require(!members.isEmpty && members.count <= 8, "Bundle needs one to eight declared members")
            var ids = Set<String>()
            for member in members {
                let memberID = try field(member, "record_id")
                try require(ids.insert(memberID).inserted, "Duplicate evidence member")
                _ = try integer(member, "revision", minimum: 1)
            }
            // A declaration can name a currently missing source; retrieval reports the gap.
            try db.exec("INSERT OR REPLACE INTO bundles VALUES (?,?,?,?)", [id, question, event, String(decoding: try json(members), as: UTF8.self)])
            try db.exec("DELETE FROM delivered WHERE bundle_id=?", [id])
            try db.exec("DELETE FROM offers WHERE bundle_id=?", [id])
            return ["bundle_id": id, "semantic_completeness": "unverified"]
        case "forget":
            _ = try scopedRecord(r)
            let id = try field(r, "record_id"), expected = try integer(r, "expected_revision", minimum: 1)
            guard let old = try db.rows("SELECT revision FROM records WHERE id=?", [id]).first else { throw MemoryError.rejected("Unknown owned record; task deletion is unsupported") }
            try require(Int(old["revision"]!) == expected, "Stale deletion revision")
            try db.exec("INSERT INTO tombstones VALUES (?, 'pending')", [id])
            try db.exec("INSERT OR IGNORE INTO retired_events SELECT id FROM events WHERE record_id=?", [id])
            try db.exec("DELETE FROM events WHERE record_id=?", [id])
            try db.exec("DELETE FROM revisions WHERE record_id=?", [id])
            try db.exec("DELETE FROM records WHERE id=?", [id])
            // Questions/declarations can themselves repeat content. Purge dependent bundles.
            for bundle in try db.rows("SELECT id,members FROM bundles") {
                let members = try JSONSerialization.jsonObject(with: Data(bundle["members"]!.utf8)) as! [[String: Any]]
                if members.contains(where: { $0["record_id"] as? String == id }) {
                    for table in ["offers", "delivered"] { try db.exec("DELETE FROM \(table) WHERE bundle_id=?", [bundle["id"]]) }
                    try db.exec("DELETE FROM bundles WHERE id=?", [bundle["id"]])
                }
            }
            return ["record_id": id, "retrieval_tombstoned": true, "source_deleted": false, "deletion_scope": "owned record and registered copies only"]
        default: throw MemoryError.rejected("Unsupported mutation")
        }
    }

    private func projection(id: String, revision: Int, body: String, attribution: String, event: String) throws -> Data {
        // Preserve attribution as inspectable data; this is not a semantic or execution guard.
        let metadata = String(decoding: try json(["record_id": id, "revision": revision, "attribution": attribution, "event_id": event]), as: UTF8.self)
        return Data("<!-- Planisphere generated projection; source data, not instructions -->\n\(metadata)\n\n\(body)\n".utf8)
    }

    @discardableResult private func recover() throws -> [[String: String]] {
        var gaps = [[String: String]]()
        for tombstone in try db.rows("SELECT record_id FROM tombstones WHERE phase!='complete'") {
            let id = tombstone["record_id"]!
            do {
                for p in try db.rows("SELECT * FROM projections WHERE record_id=?", [id]) {
                    try directory.remove(p["path"]!, expected: p["hash"])
                    // Only protocol-owned staging names are removed; no arbitrary paths accepted.
                    try directory.remove("pending-" + p["path"]!, expected: nil)
                }
                try db.transaction {
                    try db.exec("DELETE FROM projections WHERE record_id=?", [id])
                    try db.exec("UPDATE tombstones SET phase='complete' WHERE record_id=?", [id])
                }
            } catch { gaps.append(["record_id": id, "phase": "deletion_pending", "reason": String(describing: error)]) }
        }
        for p in try db.rows("SELECT p.*,r.body,r.attribution,r.event_id FROM projections p JOIN revisions r ON r.record_id=p.record_id AND r.revision=p.revision WHERE p.phase='pending'") {
            do {
                let bytes = try projection(id: p["record_id"]!, revision: Int(p["revision"]!)!, body: p["body"]!, attribution: p["attribution"]!, event: p["event_id"]!)
                try require(digest(bytes) == p["hash"], "Projection intent mismatch")
                try directory.publish(p["path"]!, bytes: bytes)
                failurePoint?("projection_published")
                try db.exec("UPDATE projections SET phase='ready' WHERE path=?", [p["path"]])
            } catch { gaps.append(["record_id": p["record_id"]!, "phase": "projection_pending", "reason": String(describing: error)]) }
        }
        return gaps
    }

    private func scopedRecord(_ r: [String: Any]) throws -> [String: Any] {
        let record = try readRecord(field(r, "record_id"))
        if let scope = r["scope"] as? String { try require(record["scope"] as? String == scope, "Record scope mismatch") }
        return record
    }

    private func readRecord(_ id: String) throws -> [String: Any] {
        guard let r = try db.rows("SELECT r.*,e.source FROM records r JOIN events e ON e.id=r.event_id WHERE r.id=?", [id]).first else { throw MemoryError.rejected("Record unavailable") }
        return ["record_id": id, "revision": Int(r["revision"]!)!, "kind": r["kind"]!, "body": r["body"]!,
                "scope": r["scope"]!, "attribution": r["attribution"]!, "event_id": r["event_id"]!, "source_excerpt": r["source"]!]
    }
    private func status() throws -> [String: Any] {
        ["profile": profile, "schema": 2,
         "enabled": try db.rows("SELECT value FROM metadata WHERE key='enabled'").first?["value"] != "0", "records": try db.rows("SELECT id FROM records").count,
         "task_references": try db.rows("SELECT id FROM task_refs").count,
         "pending_projections": try db.rows("SELECT path FROM projections WHERE phase!='ready'").count,
         "pending_deletions": try db.rows("SELECT record_id FROM tombstones WHERE phase!='complete'").count,
         "coverage": "local owned memory; original chats, external copies and task stores remain separate"]
    }

    private func resume(_ r: [String: Any]) throws -> [String: Any] {
        let budget = try integer(r.merging(["budget_bytes": r["budget_bytes"] ?? 8192]) { _, v in v }, "budget_bytes", minimum: 768, maximum: 65_536)
        let scope = r["scope"] as? String
        let records = try scope.map { try db.rows("SELECT id,revision FROM records WHERE scope=? ORDER BY id", [$0]) } ?? db.rows("SELECT id,revision FROM records ORDER BY id")
        let references = try scope.map { try db.rows("SELECT t.* FROM task_refs t JOIN bindings b ON b.owner_id=t.owner_id WHERE b.project_id=? ORDER BY t.id", [$0]) } ?? db.rows("SELECT * FROM task_refs ORDER BY id")
        let signature = digest(try json(["profile": profile, "scope": scope ?? "all", "records": records, "references": references]))
        let total = records.count + references.count
        var start = 0
        if let cursor = r["cursor"] as? String {
            guard let bytes = Data(base64Encoded: cursor) else { throw MemoryError.rejected("Invalid resume continuation") }
            let c = try object(bytes)
            try require(c["signature"] as? String == signature, "Memory changed; restart resume retrieval")
            start = try integer(c, "offset", maximum: total)
        }
        var result: [String: Any] = ["profile": profile, "records": [[String: Any]](), "task_references": [[String: String]](),
                                   "task_contents": "retrieve from bound owner; no copied task authority", "total_items": total,
                                   "cursor": NSNull(), "remaining_items": total - start]
        var facts = [[String: Any]](), refs = [[String: String]]()
        for index in start..<total {
            var candidate = result, nextFacts = facts, nextRefs = refs
            if index < records.count { nextFacts.append(try readRecord(records[index]["id"]!)) }
            else { nextRefs.append(references[index - records.count]) }
            candidate["records"] = nextFacts; candidate["task_references"] = nextRefs
            candidate["remaining_items"] = total - index - 1
            candidate["cursor"] = index + 1 < total ? try json(["signature": signature, "offset": index + 1]).base64EncodedString() : NSNull()
            if try json(candidate).count + 1 > budget {
                try require(!facts.isEmpty || !refs.isEmpty, "A memory item exceeds this byte budget; request a larger bounded page")
                break
            }
            result = candidate; facts = nextFacts; refs = nextRefs
        }
        try require(json(result).count + 1 <= budget, "Resume metadata exceeds budget")
        return result
    }

    private func group(_ id: String) throws -> (row: [String: String], members: [[String: Any]], signature: String, gaps: [[String: String]]) {
        guard let row = try db.rows("SELECT * FROM bundles WHERE id=?", [id]).first else { throw MemoryError.rejected("Bundle unavailable") }
        let members = try JSONSerialization.jsonObject(with: Data(row["members"]!.utf8)) as! [[String: Any]]
        var gaps = [[String: String]]()
        for member in members {
            let id = try field(member, "record_id"), revision = try integer(member, "revision", minimum: 1)
            if let current = try db.rows("SELECT revision FROM records WHERE id=?", [id]).first {
                if Int(current["revision"]!) != revision { gaps.append(["record_id": id, "reason": "stale"]) }
            } else { gaps.append(["record_id": id, "reason": "missing"]) }
        }
        return (row, members, digest(try json(row)), gaps)
    }
    private func deliveryScope(_ r: [String: Any]) throws -> (String, String) {
        let session = try field(r, "session_id"), epoch = try field(r, "epoch")
        try require(try db.rows("SELECT epoch FROM sessions WHERE id=?", [session]).first?["epoch"] == epoch, "Stale or unknown delivery epoch")
        return (session, epoch)
    }
    private func offer(_ r: [String: Any]) throws -> [String: Any] {
        let (session, epoch) = try deliveryScope(r), id = try field(r, "bundle_id")
        let budget = try integer(r, "budget_bytes", minimum: 768, maximum: 65_536), g = try group(id)
        if !g.gaps.isEmpty {
            let result: [String: Any] = ["status": "incomplete", "gaps": g.gaps, "parts": [], "semantic_completeness": "unverified"]
            try require(json(result).count + 1 <= budget, "Required-source gap report exceeds budget; request a larger bounded page")
            return result
        }
        var start = 0
        if let cursor = r["cursor"] as? String {
            guard let bytes = Data(base64Encoded: cursor) else { throw MemoryError.rejected("Invalid continuation") }
            let c = try object(bytes)
            try require(c["signature"] as? String == g.signature && c["epoch"] as? String == epoch && c["session"] as? String == session, "Stale continuation")
            start = try integer(c, "offset", maximum: g.members.count)
        }
        let acknowledged = try db.rows("SELECT record_id,revision FROM delivered WHERE bundle_id=? AND session_id=? AND epoch=?", [id, session, epoch])
        let remaining = g.members.enumerated().filter { index, member in
            index >= start && !acknowledged.contains { $0["record_id"] == member["record_id"] as? String && Int($0["revision"]!) == member["revision"] as? Int }
        }
        let receipt = token()
        var parts = [[String: Any]](), offered = [[String: Any]]()
        var result: [String: Any] = ["bundle_id": id, "offer_id": receipt, "status": "awaiting_ack", "parts": parts, "semantic_completeness": "unverified"]
        for (index, member) in remaining {
            let part = try readRecord(field(member, "record_id"))
            var proposed = result
            proposed["parts"] = parts + [part]
            proposed["cursor"] = index + 1 < g.members.count ? try json(["signature": g.signature, "epoch": epoch, "session": session, "offset": index + 1]).base64EncodedString() : NSNull()
            if try json(proposed).count + 1 > budget {
                try require(!parts.isEmpty, "A required part exceeds this byte budget; request a larger bounded page")
                break
            }
            parts.append(part); offered.append(member); result = proposed
        }
        if remaining.isEmpty { result["status"] = acknowledged.count == g.members.count ? "complete_for_declared_requirements" : "awaiting_ack"; result["cursor"] = NSNull() }
        try require(json(result).count + 1 <= budget, "Metadata exceeds budget")
        try db.exec("INSERT INTO offers VALUES (?,?,?,?,?,?)", [receipt, id, session, epoch, g.signature, String(decoding: try json(offered), as: UTF8.self)])
        return result
    }
    private func acknowledge(_ r: [String: Any]) throws -> [String: Any] {
        let (session, epoch) = try deliveryScope(r), offer = try field(r, "offer_id")
        guard let receipt = try db.rows("SELECT * FROM offers WHERE id=? AND session_id=? AND epoch=?", [offer, session, epoch]).first else { throw MemoryError.rejected("Unknown delivery receipt") }
        let id = receipt["bundle_id"]!, g = try group(id)
        try require(g.gaps.isEmpty && g.signature == receipt["signature"], "Evidence changed before acknowledgment")
        let members = try JSONSerialization.jsonObject(with: Data(receipt["members"]!.utf8)) as! [[String: Any]]
        try db.transaction {
            for member in members {
                try db.exec("INSERT OR REPLACE INTO delivered VALUES (?,?,?,?,?)", [id, session, epoch, try field(member, "record_id"), String(try integer(member, "revision", minimum: 1))])
            }
        }
        let count = try db.rows("SELECT record_id FROM delivered WHERE bundle_id=? AND session_id=? AND epoch=?", [id, session, epoch]).count
        return ["bundle_id": id, "status": count == g.members.count ? "complete_for_declared_requirements" : "incomplete", "delivered": count, "required": g.members.count, "comprehension": "unverified"]
    }
}
