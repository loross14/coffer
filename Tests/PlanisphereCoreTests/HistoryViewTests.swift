import XCTest
import Foundation
@testable import PlanisphereCore

final class HistoryViewTests: XCTestCase, @unchecked Sendable {
    typealias Fixture = VaultStoreTests.Fixture

    func testHistoryViewIncludesVerifiedComparisonAndPreviewAndRechecksCorruption() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("a.md", "before")
        let v = try await f.store.register(url: f.source)
        let first = try await f.store.createCheckpoint(vaultID: v.id, message: "one")
        try f.write("a.md", "after")
        let last = try await f.store.createCheckpoint(vaultID: v.id, message: "two")
        let view = try await f.store.historyView(vaultID: v.id)
        XCTAssertEqual(view.checkpoints.map(\.id), [last.id, first.id])
        XCTAssertEqual(view.beforeText, "before"); XCTAssertEqual(view.afterText, "after")
        XCTAssertEqual(view.selectedChangePath, "a.md")
        let older = try await f.store.historyView(vaultID: v.id, checkpointID: first.id)
        XCTAssertNil(older.beforeText); XCTAssertEqual(older.afterText, "before")
        // A prior successful read must not cache away corruption in an old object.
        let digest = try XCTUnwrap(first.entries.first?.digest)
        try Data("broken".utf8).write(to: f.storeURL.appendingPathComponent("objects/" + digest))
        do { _ = try await f.store.historyView(vaultID: v.id); XCTFail("Corruption was accepted") }
        catch { XCTAssertFalse(error is CancellationError) }
    }

    func testRecoveryRecordsAndHistoryRemainAvailableTogether() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("a.md", "before")
        let v = try await f.store.register(url: f.source)
        for (before, after) in [("before", "middle"), ("middle", "after")] {
            let review = try await f.store.checkpointPlan(vaultID: v.id, mode: .markdownOnly)
            let plan = try MarkdownMutationPlan(vaultID: v.id, vaultPath: v.path, scope: XCTUnwrap(review.scope),
                expectedFiles: ["a.md": VaultFS.hash(Data(before.utf8))],
                changes: [MarkdownMutation(path: "a.md", before: Data(before.utf8), after: Data(after.utf8))])
            _ = try await f.store.applyMarkdownMutation(plan)
        }
        let view = try await f.store.historyView(vaultID: v.id)
        XCTAssertEqual(view.mutationReceipts.count, 2); XCTAssertNil(view.recoveryError)
        XCTAssertEqual(view.checkpoints.count, 4); XCTAssertEqual(view.afterText, "after")
        let journal = f.storeURL.appendingPathComponent("vaults/\(v.id.uuidString)/mutations/\(view.mutationReceipts[0].id.uuidString).json")
        try Data("corrupt".utf8).write(to: journal)
        let damaged = try await f.store.historyView(vaultID: v.id)
        XCTAssertNotNil(damaged.recoveryError); XCTAssertTrue(damaged.mutationReceipts.isEmpty)
        XCTAssertEqual(damaged.checkpoints.count, 4)
    }

    func testCompiledScopePreservesExactPrefixAndUnicodeBehavior() throws {
        let rules = ["a/", "foo/bar", "é/", "👩‍💻/"].sorted()
        for mode in [CheckpointMode.markdownOnly, .vaultContent] {
            let scope = CheckpointScope(excludedPaths: rules, sourceConfigurationSHA256: nil, mode: mode)
            let targets = Set(rules.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
            for path in ["a", "a/b.md", "ab/c.md", "foo/bar", "foo/bar/b.md", "foo/barley.md", "é/a.md", "e\u{301}/a.md", "👩‍💻/a.md", ".planisphere/settings.json", "node_modules", "good.md", "file.bin"] {
                for directory in [false, true] {
                    XCTAssertEqual(scope.exclusionReason(path, isDirectory: directory),
                                   scope.exclusionReason(path, isDirectory: directory, excludedTargets: targets), path)
                }
            }
        }
    }

    func testCancelledReadReleasesStoreAndDoesNotChangeHistory() async throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write("a.md", "saved")
        let v = try await f.store.register(url: f.source)
        let checkpoint = try await f.store.createCheckpoint(vaultID: v.id, message: "one")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.store.historyView(vaultID: v.id)
        }
        do { _ = try await task.value; XCTFail("Cancelled read completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await f.store.historyView(vaultID: v.id)
        XCTAssertEqual(next.checkpoints.map(\.id), [checkpoint.id]); XCTAssertEqual(next.afterText, "saved")
    }
}
