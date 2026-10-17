import XCTest
import Foundation
@testable import PlanisphereCore

final class VaultChangeWatcherTests: XCTestCase, @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeVault() throws -> URL {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PlanisphereWatcher-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func settle(_ seconds: TimeInterval) {
        let waiter = expectation(description: "settle")
        waiter.isInverted = true
        wait(for: [waiter], timeout: seconds)
    }

    func testHiddenFoldersAreNotVaultChanges() {
        let roots = ["/v", "/private/v"]
        XCTAssertFalse(VaultChangeWatcher.isRelevant("/v", roots: roots), "the root folder's own entry changes with every child")
        XCTAssertTrue(VaultChangeWatcher.isRelevant("/v/notes/a.md", roots: roots))
        XCTAssertTrue(VaultChangeWatcher.isRelevant("/private/v/a.md", roots: roots))
        XCTAssertFalse(VaultChangeWatcher.isRelevant("/v/.obsidian/workspace.json", roots: roots))
        XCTAssertFalse(VaultChangeWatcher.isRelevant("/v/.git/index", roots: roots))
        XCTAssertFalse(VaultChangeWatcher.isRelevant("/v/notes/.planisphere-recovery/x", roots: roots))
        XCTAssertTrue(VaultChangeWatcher.isRelevant("/v/notes/not.hidden/a.md", roots: roots))
        XCTAssertTrue(VaultChangeWatcher.isRelevant("/elsewhere/a.md", roots: roots), "an unrecognised path refreshes rather than being dropped")
    }

    func testOneWriteBecomesOneRefreshAndHiddenWritesNone() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let counter = Counter()
        let watcher = VaultChangeWatcher(root: vault, quiet: 0.6) { counter.bump() }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        settle(0.5)

        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: vault.appendingPathComponent(".obsidian/workspace.json"))
        settle(2.0)
        XCTAssertEqual(counter.count, 0, "editor state under a hidden folder is not a vault change")

        try Data("# One\n".utf8).write(to: vault.appendingPathComponent("one.md"))
        settle(3.0)
        XCTAssertEqual(counter.count, 1)
    }

    /// An import that writes thousands of notes must not reload the graph once per file.
    func testLargeImportIsCoalescedIntoOneRefresh() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let counter = Counter()
        let watcher = VaultChangeWatcher(root: vault, quiet: 1.0) { counter.bump() }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        settle(0.5)

        let folder = vault.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = Date()
        for index in 0..<5_000 {
            try Data("# Note \(index)\n[[note-\((index + 1) % 5_000)]]\n".utf8)
                .write(to: folder.appendingPathComponent("note-\(index).md"))
        }
        let writing = Date().timeIntervalSince(started)
        settle(writing + 4.0)
        XCTAssertEqual(counter.count, 1, "5,000 writes in \(String(format: "%.2f", writing))s should coalesce into one refresh")
        settle(2.0)
        XCTAssertEqual(counter.count, 1, "no trailing refreshes once the vault is quiet")
    }

    func testStopEndsDelivery() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let counter = Counter()
        let watcher = VaultChangeWatcher(root: vault, quiet: 0.3) { counter.bump() }
        XCTAssertTrue(watcher.start())
        watcher.stop()
        try Data("x".utf8).write(to: vault.appendingPathComponent("after-stop.md"))
        settle(1.5)
        XCTAssertEqual(counter.count, 0)
    }
}
