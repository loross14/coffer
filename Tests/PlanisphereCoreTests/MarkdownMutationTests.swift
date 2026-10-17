import XCTest
import Foundation
import Darwin
@testable import PlanisphereCore

final class MarkdownMutationTests: XCTestCase, @unchecked Sendable {
    private typealias Fixture = VaultStoreTests.Fixture
    private let originals = ["a.md": "# Original A\n", "nested/b.md": "# Original B\n", "untouched.md": "# Untouched\n"]

    private func setup(_ f: Fixture) async throws -> (VaultRecord, MarkdownMutationPlan) {
        for (path, text) in originals { try f.write(path, text) }
        try f.write(".planisphere/scope.json", #"{"excludedPaths":[]}"#)
        try f.write("attachment.bin", Data([0, 255, 1]))
        let vault = try await f.store.register(url: f.source)
        let review = try await f.store.checkpointPlan(vaultID: vault.id, mode: .markdownOnly)
        let scope = try XCTUnwrap(review.scope)
        let changes = [MarkdownMutation(path: "a.md", before: Data(originals["a.md"]!.utf8), after: Data("# Kept A\n".utf8)),
                       MarkdownMutation(path: "nested/b.md", before: Data(originals["nested/b.md"]!.utf8), after: nil)]
        let plan = try MarkdownMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: scope,
                                            expectedFiles: originals.mapValues { VaultFS.hash(Data($0.utf8)) }, changes: changes,
                                            reviewedPacket: Data("exact local review provenance".utf8))
        return (vault, plan)
    }

    private func expectFailure<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected refusal", file: file, line: line) }
        catch {}
    }

    func testApprovedNonGitMutationCheckpointsRecoveryCopiesAndIdempotency() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let legacy = try await f.store.createCheckpoint(vaultID: vault.id, message: "Legacy full folder")
        XCTAssertEqual(legacy.formatVersion, 1)
        let receipt = try await f.store.applyMarkdownMutation(plan)
        XCTAssertEqual(receipt.status, .completed)
        XCTAssertEqual(receipt.appliedPaths, plan.changes.map(\.path))
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.md"), encoding: .utf8), "# Kept A\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("nested/b.md").path))
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("attachment.bin")), Data([0, 255, 1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.appendingPathComponent(".git").path))
        for (index, path) in receipt.recoveryPaths.enumerated() {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), plan.changes[index].before)
        }
        let versions = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(versions.map(\.id), [try XCTUnwrap(receipt.afterCheckpointID), receipt.beforeCheckpointID, legacy.id])
        XCTAssertEqual(versions[0].captureScope, plan.scope)
        XCTAssertEqual(versions[0].entries.filter { $0.kind == .file }.map(\.path), ["a.md", "untouched.md"])
        let again = try await f.store.applyMarkdownMutation(plan)
        XCTAssertEqual(again, receipt)
        let reopened = try VaultStore(rootURL: f.storeURL)
        let reopenedReceipts = try await reopened.mutationReceipts(vaultID: vault.id)
        XCTAssertEqual(reopenedReceipts, [receipt])
        let restored = try await reopened.restoreCopy(vaultID: vault.id, checkpointID: receipt.beforeCheckpointID,
                                                      destination: f.base.appendingPathComponent("Recovered"))
        for (path, text) in originals { XCTAssertEqual(try String(contentsOf: restored.url.appendingPathComponent(path), encoding: .utf8), text) }
        let exported = try await reopened.exportVault(vaultID: vault.id, destination: f.base.appendingPathComponent("Export"))
        XCTAssertEqual(try String(contentsOf: exported.appendingPathComponent("files/a.md"), encoding: .utf8), "# Kept A\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("files/nested/b.md").path))
        // Reusing an operation ID for a different valid plan cannot rebind its receipt.
        let different = try MarkdownMutationPlan(id: plan.id, vaultID: vault.id, vaultPath: vault.path, scope: plan.scope,
                                                 expectedFiles: plan.expectedFiles, changes: Array(plan.changes.prefix(1)))
        await expectFailure { try await reopened.applyMarkdownMutation(different) }
    }

    func testStaleInventoryAndSettingsRefuseBeforeAnySourceMutation() async throws {
        for scenario in ["unrelated-note", "new-note", "settings"] {
            let f = try Fixture(); defer { f.clean() }
            let (vault, plan) = try await setup(f)
            if scenario == "unrelated-note" { try f.write("untouched.md", "editor changed this") }
            if scenario == "new-note" { try f.write("new.md", "new note") }
            if scenario == "settings" { try f.write(".planisphere/scope.json", #"{"excludedPaths":["untouched.md"]}"#) }
            await expectFailure { try await f.store.applyMarkdownMutation(plan) }
            XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.md"), encoding: .utf8), originals["a.md"])
            let history = try await f.store.checkpoints(vaultID: vault.id)
            let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
            XCTAssertTrue(history.isEmpty)
            XCTAssertTrue(receipts.isEmpty)
        }
    }

    func testConcurrentEditBeforeExchangeIsNeverReplaced() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let target = f.source.appendingPathComponent("a.md")
        await f.store.setMutationStepHook { index, phase in
            if index == 0 && phase == "beforeExchange" { try Data("editor wins".utf8).write(to: target) }
        }
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "editor wins")
        let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
        XCTAssertEqual(receipts.first?.status, .interrupted)
        XCTAssertEqual(receipts.first?.appliedPaths, [])
        XCTAssertNil(receipts.first?.afterCheckpointID)
        let history = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(history.count, 1)
    }

    func testNarrowExchangeRacePreservesActuallyDisplacedEditorBytes() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let target = f.source.appendingPathComponent("a.md")
        await f.store.setMutationStepHook { index, phase in
            if index == 0 && phase == "exchangeBoundary" { try Data("last-instant editor bytes".utf8).write(to: target) }
        }
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
        let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.status, .interrupted)
        XCTAssertEqual(try String(contentsOfFile: receipt.recoveryPaths[0], encoding: .utf8), "last-instant editor bytes")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Kept A\n")
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("nested/b.md"), encoding: .utf8), originals["nested/b.md"])
    }

    func testLateWriteThroughOriginalDescriptorRemainsRecoverableAfterCompletion() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (_, plan) = try await setup(f)
        let descriptor = open(f.source.appendingPathComponent("a.md").path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let receipt = try await f.store.applyMarkdownMutation(plan)
        let bytes = Data("late editor save".utf8)
        XCTAssertEqual(ftruncate(descriptor, 0), 0)
        try bytes.withUnsafeBytes { try VaultFS.writeAll(descriptor, $0) }
        try VaultFS.sync(descriptor)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.recoveryPaths[0])), bytes)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.md"), encoding: .utf8), "# Kept A\n")
    }

    func testPartialFailureKeepsRecoveryAndRefusesAfterCheckpointForUnreviewedEdits() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let unrelated = f.source.appendingPathComponent("untouched.md")
        await f.store.setMutationStepHook { _, phase in
            if phase == "beforeAfterCheckpoint" { try Data("unreviewed edit".utf8).write(to: unrelated) }
        }
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
        let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.status, .interrupted)
        XCTAssertNil(receipt.afterCheckpointID)
        let history = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unreviewed edit")
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
    }

    func testSymlinkReplacementDuringApplyCannotReachOutsideVault() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let target = f.source.appendingPathComponent("a.md")
        let outside = f.base.appendingPathComponent("external.md")
        try Data("outside untouched".utf8).write(to: outside)
        await f.store.setMutationStepHook { index, phase in
            if index == 0 && phase == "beforeExchange" {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            }
        }
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside untouched")
        let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
        XCTAssertEqual(receipts.first?.status, .interrupted)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), outside.path)
    }

    func testInterruptedOperationBlocksFreshPlanUntilExplicitRecoveryAcknowledgment() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        await f.store.setMutationStepHook { index, phase in
            if index == 0 && phase == "afterExchange" { throw VaultStoreError.unavailable("Injected interruption") }
        }
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
        await f.store.setMutationStepHook(nil)
        var currentFiles = plan.expectedFiles
        currentFiles["a.md"] = VaultFS.hash(Data("# Kept A\n".utf8))
        let fresh = try MarkdownMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: plan.scope,
                                             expectedFiles: currentFiles, changes: [plan.changes[1]])
        await expectFailure { try await f.store.applyMarkdownMutation(fresh) }
        let blockedHistory = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(blockedHistory.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("nested/b.md").path))
        let acknowledged = try await f.store.acknowledgeMutationRecovery(vaultID: vault.id, operationID: plan.id)
        XCTAssertEqual(acknowledged.status, .interrupted)
        XCTAssertNotNil(acknowledged.recoveryAcknowledgedAt)
        XCTAssertNil(acknowledged.afterCheckpointID)
        XCTAssertEqual(try String(contentsOfFile: acknowledged.recoveryPaths[0], encoding: .utf8), originals["a.md"])
        // Acknowledgment never authorizes replay of the interrupted operation.
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
        let completed = try await f.store.applyMarkdownMutation(fresh)
        XCTAssertEqual(completed.status, .completed)
        let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts.first?.id, fresh.id)
        XCTAssertEqual(receipts.last, acknowledged)
        await expectFailure { try await f.store.acknowledgeMutationRecovery(vaultID: vault.id, operationID: fresh.id) }
    }

    func testUnsafeOrCorruptPlansAndJournalsFailClosed() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let broadScope = CheckpointScope(excludedPaths: [], sourceConfigurationSHA256: nil)
        XCTAssertThrowsError(try MarkdownMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: broadScope,
                                                      expectedFiles: plan.expectedFiles, changes: plan.changes))
        XCTAssertThrowsError(try MarkdownMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: plan.scope,
                                                      expectedFiles: plan.expectedFiles,
                                                      changes: [MarkdownMutation(path: "../a.md", before: plan.changes[0].before, after: nil)]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: VaultFormat.encode(plan)) as? [String: Any])
        object["digest"] = String(repeating: "0", count: 64)
        let corrupt = try VaultFormat.decode(MarkdownMutationPlan.self, from: JSONSerialization.data(withJSONObject: object))
        await expectFailure { try await f.store.applyMarkdownMutation(corrupt) }
        let receipt = try await f.store.applyMarkdownMutation(plan)
        let journalPath = f.storeURL.appendingPathComponent("vaults/\(vault.id.uuidString)/mutations/\(plan.id.uuidString).json")
        try Data("broken".utf8).write(to: journalPath)
        await expectFailure { try await f.store.mutationReceipts(vaultID: vault.id) }
        await expectFailure { try await f.store.applyMarkdownMutation(plan) }
        XCTAssertEqual(try String(contentsOfFile: receipt.recoveryPaths[0], encoding: .utf8), originals["a.md"])
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.md"), encoding: .utf8), "# Kept A\n")
    }

    func testCrashChildHelper() async throws {
        guard let root = ProcessInfo.processInfo.environment["PLANISPHERE_MUTATION_CRASH_ROOT"],
              let planPath = ProcessInfo.processInfo.environment["PLANISPHERE_MUTATION_CRASH_PLAN"] else { return }
        let store = try VaultStore(rootURL: URL(fileURLWithPath: root))
        let plan = try VaultFormat.decode(MarkdownMutationPlan.self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        await store.setMutationStepHook { index, phase in
            if index == 0 && phase == "afterExchange" { _exit(73) }
        }
        _ = try await store.applyMarkdownMutation(plan)
        XCTFail("Expected abrupt process termination")
    }

    func testAbruptProcessExitLeavesDurablePendingReceiptAndRestorableCheckpoint() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let path = f.base.appendingPathComponent("review.json")
        try VaultFormat.encode(plan).write(to: path)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "PlanisphereCoreTests.MarkdownMutationTests/testCrashChildHelper", Bundle(for: MarkdownMutationTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PLANISPHERE_MUTATION_CRASH_ROOT"] = f.storeURL.path
        environment["PLANISPHERE_MUTATION_CRASH_PLAN"] = path.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 73)
        let reopened = try VaultStore(rootURL: f.storeURL)
        let receipts = try await reopened.mutationReceipts(vaultID: vault.id)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.status, .interrupted)
        XCTAssertNil(receipt.afterCheckpointID)
        XCTAssertEqual(try String(contentsOfFile: receipt.recoveryPaths[0], encoding: .utf8), originals["a.md"])
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.md"), encoding: .utf8), "# Kept A\n")
        let restored = try await reopened.restoreCopy(vaultID: vault.id, checkpointID: receipt.beforeCheckpointID,
                                                      destination: f.base.appendingPathComponent("Crash recovery"))
        for (path, text) in originals { XCTAssertEqual(try String(contentsOf: restored.url.appendingPathComponent(path), encoding: .utf8), text) }
        await expectFailure { try await reopened.applyMarkdownMutation(plan) }
    }
}
