import XCTest
import Foundation
@testable import PlanisphereMemory

final class MemoryStoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/memory-test-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func store(_ profile: String = "person-a") throws -> MemoryStore { try MemoryStore(directory: root, profile: profile) }
    func request(_ action: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        ["action": action, "profile": "person-a", "operation_id": UUID().uuidString].merging(fields) { _, new in new }
    }
    func commit(_ id: String = "fact", revision: Int = 0, body: String = "Use the blue sample.") -> [String: Any] {
        request("commit", ["record_id": id, "expected_revision": revision, "body": body,
                           "source_excerpt": "User explicitly chose this sample.", "event_id": UUID().uuidString,
                           "attribution": "human_statement", "kind": "preference"])
    }
    func session(_ s: MemoryStore) throws -> [String: Any] { try s.handle(request("session", ["session_id": "chat-a"])) }
    func declare(_ s: MemoryStore, members: [[String: Any]]) throws {
        _ = try s.handle(request("bundle", ["bundle_id": "answer", "question": "Which sample under which condition?",
                                            "declaration_event": "declaration-1", "all_of": members]))
    }
    func offer(_ s: MemoryStore, _ epoch: [String: Any], budget: Int = 4096, cursor: String? = nil) throws -> [String: Any] {
        var fields = epoch
        fields["bundle_id"] = "answer"; fields["budget_bytes"] = budget
        if let cursor { fields["cursor"] = cursor }
        return try s.handle(request("offer", fields))
    }
    func ack(_ s: MemoryStore, _ epoch: [String: Any], _ page: [String: Any]) throws -> [String: Any] {
        try s.handle(request("ack", epoch.merging(["offer_id": page["offer_id"]!]) { _, new in new }))
    }

    func testRestartCorrectionAndReplay() throws {
        let create = commit()
        do {
            let s = try store()
            XCTAssertEqual(try s.handle(create)["accepted_revision"] as? Int, 1)
            _ = try s.handle(create)
            var altered = create; altered["body"] = "Changed event reuse"
            XCTAssertThrowsError(try s.handle(altered))
            _ = try s.handle(commit(revision: 1, body: "Use green, correcting blue."))
            XCTAssertThrowsError(try s.handle(commit(revision: 1, body: "Stale writer")))
        }
        let resumed = try store().handle(request("resume"))
        let records = resumed["records"] as! [[String: Any]]
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["body"] as? String, "Use green, correcting blue.")
        XCTAssertEqual(records[0]["revision"] as? Int, 2)
    }

    func testProfileIsolationAndOwnerBinding() throws {
        let s = try store()
        _ = try s.handle(commit())
        XCTAssertThrowsError(try store("person-b"))
        XCTAssertThrowsError(try s.handle(request("resume", ["profile": "person-b"])))
        let ref = request("reference_task", ["reference_id": "task-link", "owner_id": "owner-a", "task_id": "task-a", "source_revision": 2])
        XCTAssertThrowsError(try s.handle(ref))
        _ = try s.handle(request("bind_owner", ["owner_id": "owner-a", "host_id": "installation-a", "project_id": "project-a"]))
        _ = try s.handle(ref)
        XCTAssertThrowsError(try s.handle(request("bind_owner", ["owner_id": "owner-a", "host_id": "installation-b", "project_id": "project-a"])))
        let result = try s.handle(request("forget_reference", ["reference_id": "task-link"]))
        XCTAssertEqual(result["source_deleted"] as? Bool, false)
        XCTAssertThrowsError(try s.handle(request("forget", ["record_id": "task-a", "expected_revision": 1])))
    }

    func testForgetPurgesOwnedBodiesAndRejectsDelayedReplay() throws {
        let secret = "unique-private-canary-\(UUID().uuidString)"
        let create = commit(body: secret)
        do {
            let s = try store()
            _ = try s.handle(create)
            try declare(s, members: [["record_id": "fact", "revision": 1]])
            let epoch = try session(s), page = try offer(s, epoch)
            _ = try ack(s, epoch, page)
            let result = try s.handle(request("forget", ["record_id": "fact", "expected_revision": 1]))
            XCTAssertEqual(result["deletion_state"] as? String, "complete")
            XCTAssertThrowsError(try s.handle(request("inspect", ["record_id": "fact"])))
            // The old receipt is replayable metadata, never a cached memory body.
            _ = try s.handle(create)
            var delayed = create; delayed["operation_id"] = UUID().uuidString; delayed["record_id"] = "different-record"
            XCTAssertThrowsError(try s.handle(delayed))
            XCTAssertThrowsError(try offer(s, epoch))
        }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(secret.utf8)), file.lastPathComponent)
        }
    }

    func testEditedProjectionKeepsDeletionPending() throws {
        let s = try store()
        _ = try s.handle(commit())
        let file = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "md" }!
        let userBytes = Data("Human edit must survive".utf8)
        try userBytes.write(to: file)
        let result = try s.handle(request("forget", ["record_id": "fact", "expected_revision": 1]))
        XCTAssertEqual(result["deletion_state"] as? String, "pending")
        XCTAssertEqual(try Data(contentsOf: file), userBytes)
        XCTAssertThrowsError(try s.handle(request("inspect", ["record_id": "fact"])))
        XCTAssertEqual(try s.handle(request("status"))["pending_deletions"] as? Int, 1)
    }

    func testRequiredPartsArePagedAndAcknowledgedTogether() throws {
        let s = try store()
        _ = try s.handle(commit("claim", body: String(repeating: "a", count: 600)))
        _ = try s.handle(commit("condition", body: String(repeating: "b", count: 600)))
        try declare(s, members: [["record_id": "claim", "revision": 1], ["record_id": "condition", "revision": 1]])
        let epoch = try session(s), first = try offer(s, epoch, budget: 1450)
        XCTAssertLessThanOrEqual(try json(first).count, 1450)
        XCTAssertEqual((first["parts"] as! [[String: Any]]).count, 1)
        XCTAssertEqual(try ack(s, epoch, first)["status"] as? String, "incomplete")
        let second = try offer(s, epoch, budget: 1450, cursor: first["cursor"] as? String)
        XCTAssertLessThanOrEqual(try json(second).count, 1450)
        XCTAssertEqual(try ack(s, epoch, second)["status"] as? String, "complete_for_declared_requirements")
        let repeated = try offer(s, epoch, budget: 1450)
        XCTAssertEqual((repeated["parts"] as! [[String: Any]]).count, 0)
        let reset = try session(s)
        XCTAssertThrowsError(try ack(s, epoch, first))
        XCTAssertEqual((try offer(s, reset, budget: 1450)["parts"] as! [[String: Any]]).count, 1)
    }

    func testCorrectionInvalidatesOffersAndContinuations() throws {
        let s = try store()
        _ = try s.handle(commit("claim")); _ = try s.handle(commit("condition"))
        try declare(s, members: [["record_id": "claim", "revision": 1], ["record_id": "condition", "revision": 1]])
        let epoch = try session(s), page = try offer(s, epoch)
        _ = try s.handle(commit("condition", revision: 1, body: "Corrected condition"))
        XCTAssertThrowsError(try ack(s, epoch, page))
        let stale = try offer(s, epoch)
        XCTAssertEqual(stale["status"] as? String, "incomplete")
        XCTAssertEqual((stale["parts"] as! [Any]).count, 0)
        XCTAssertEqual((stale["gaps"] as! [[String: String]])[0]["reason"], "stale")
    }

    func testMissingQualificationAndSmallBudgetNeverYieldComplete() throws {
        let s = try store()
        _ = try s.handle(commit("claim", body: String(repeating: "x", count: 1800)))
        try declare(s, members: [["record_id": "claim", "revision": 1], ["record_id": "missing", "revision": 1]])
        let epoch = try session(s)
        XCTAssertEqual(try offer(s, epoch)["status"] as? String, "incomplete")
        try declare(s, members: [["record_id": "claim", "revision": 1]])
        XCTAssertThrowsError(try offer(s, epoch, budget: 768))
        XCTAssertEqual(try offer(s, epoch, budget: 4000)["status"] as? String, "awaiting_ack")
    }

    func testInvalidNumericAndTaskBodiesRejected() throws {
        let s = try store()
        var bad = commit(); bad["expected_revision"] = true
        XCTAssertThrowsError(try s.handle(bad))
        bad = commit(); bad["expected_revision"] = 0.5
        XCTAssertThrowsError(try s.handle(bad))
        bad = commit(); bad["kind"] = "task"
        XCTAssertThrowsError(try s.handle(bad))
    }

    func testResumePagesAreBoundedAndRejectChangedSnapshots() throws {
        let s = try store()
        for id in ["a", "b", "c"] { _ = try s.handle(commit(id, body: String(repeating: id, count: 400))) }
        let first = try s.handle(request("resume", ["budget_bytes": 1200]))
        XCTAssertLessThanOrEqual(try json(first).count + 1, 1200)
        XCTAssertEqual((first["records"] as! [[String: Any]]).count, 1)
        let second = try s.handle(request("resume", ["budget_bytes": 1200, "cursor": first["cursor"]!]))
        XCTAssertEqual((second["records"] as! [[String: Any]])[0]["record_id"] as? String, "b")
        _ = try s.handle(commit("a", revision: 1, body: "New correction"))
        XCTAssertThrowsError(try s.handle(request("resume", ["budget_bytes": 1200, "cursor": second["cursor"]!])))
    }

    func testGapMetadataCannotOverflowDeliveryBudget() throws {
        let s = try store()
        try declare(s, members: (0..<8).map { ["record_id": String(repeating: "x", count: 180) + String($0), "revision": 1] })
        let epoch = try session(s)
        XCTAssertThrowsError(try offer(s, epoch, budget: 768))
        XCTAssertLessThanOrEqual(try json(offer(s, epoch, budget: 4096)).count + 1, 4096)
    }

    func testSymlinkAndHardLinkedDatabaseRejected() throws {
        let original = root.appendingPathExtension("original")
        defer { try? FileManager.default.removeItem(at: original) }
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: original)
        XCTAssertThrowsError(try store())
        try FileManager.default.removeItem(at: root)
        _ = try store()
        try FileManager.default.linkItem(at: root.appendingPathComponent("memory.sqlite3"), to: original.appendingPathComponent("linked.sqlite3"))
        XCTAssertThrowsError(try store())
    }
}
