import XCTest
import Foundation
@testable import PlanisphereApp
import PlanisphereCore

@MainActor final class HistoryLoadingTests: XCTestCase {
    func testSwitchAndCancelDoNotTrapNavigationOrApplyStaleHistory() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/HistoryUI-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(rootURL: root.appendingPathComponent("store"))
        let a = try await store.create(at: root.appendingPathComponent("a"))
        let b = try await store.create(at: root.appendingPathComponent("b"))
        try Data("a".utf8).write(to: a.url.appendingPathComponent("note.md"))
        try Data("b".utf8).write(to: b.url.appendingPathComponent("note.md"))
        _ = try await store.createCheckpoint(vaultID: a.id, message: "a")
        let latest = try await store.createCheckpoint(vaultID: b.id, message: "b")
        let model = VaultAppModel(dataDirectory: root.appendingPathComponent("store"))
        model.vaults = [a, b]
        model.selectVault(a.id)
        XCTAssertTrue(model.isHistoryLoading); XCTAssertTrue(model.canNavigateWorkspace)
        model.selectVault(b.id)
        for _ in 0..<200 where model.isHistoryLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy); XCTAssertEqual(model.selectedVaultID, b.id)
        XCTAssertEqual(model.selectedCheckpointID, latest.id); XCTAssertEqual(model.afterText, "b")
        model.retryHistory(); model.cancelHistoryLoad()
        for _ in 0..<200 where model.isHistoryLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy); XCTAssertTrue(model.canNavigateWorkspace)
        XCTAssertTrue(model.historyReadError?.contains("cancelled") == true)
        model.retryHistory()
        for _ in 0..<200 where model.isHistoryLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.historyReadError); XCTAssertEqual(model.afterText, "b")
    }
}
