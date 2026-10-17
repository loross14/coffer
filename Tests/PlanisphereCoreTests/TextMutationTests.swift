import XCTest
import Foundation
import Darwin
@testable import PlanisphereCore

final class TextMutationTests: XCTestCase, @unchecked Sendable {
    private typealias Fixture = VaultStoreTests.Fixture
    private let original = Data("\\section{Before}\n".utf8)
    private let replacement = Data("\\section{Qualified}\n".utf8)

    private func setup(_ f: Fixture) async throws -> (VaultRecord, TextMutationPlan) {
        try f.write("paper/main.tex", original)
        try f.write("build.py", "print('before')\n")
        XCTAssertEqual(chmod(f.source.appendingPathComponent("build.py").path, 0o700), 0)
        try f.write("attachment.bin", Data([0, 255, 1]))
        try f.write("untouched.md", "retained\n")
        try f.write("excluded/keep.tex", "excluded\n")
        try f.write(".planisphere/scope.json", #"{"excludedPaths":["excluded"]}"#)
        try FileManager.default.createDirectory(at: f.source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("reference.tex").path, withDestinationPath: "paper/main.tex")
        let vault = try await f.store.register(url: f.source)
        let review = try await f.store.checkpointPlan(vaultID: vault.id, mode: .vaultContent)
        let scope = try XCTUnwrap(review.scope)
        let checkpoint = try await f.store.createCheckpoint(vaultID: vault.id, message: "Reviewed source baseline", scope: scope)
        let plan = try TextMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: scope,
            expectedEntries: checkpoint.entries, extensions: ["py", "tex"], changes: [
                TextMutation(path: "paper/main.tex", before: original, after: replacement),
                TextMutation(path: "build.py", before: Data("print('before')\n".utf8), after: Data("print('after')\n".utf8))
            ], reviewedPacket: Data("Exact, authorized text repairs".utf8))
        return (vault, plan)
    }

    private func fails<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected refusal", file: file, line: line) } catch {}
    }

    func testTextRepairPinsFullInventoryRestoresAndPreservesPermissions() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let encoded = try VaultFormat.encode(plan)
        let decoded = try VaultFormat.decode(TextMutationPlan.self, from: encoded)
        XCTAssertEqual(decoded, plan)
        let receipt = try await f.store.applyTextMutation(decoded)
        XCTAssertEqual(receipt.status, .completed)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("paper/main.tex")), replacement)
        let delta = try await f.store.changes(vaultID: vault.id, from: receipt.beforeCheckpointID, to: XCTUnwrap(receipt.afterCheckpointID))
        XCTAssertEqual(Set(delta.map(\.path)), Set(plan.changes.map(\.path)))
        XCTAssertTrue(delta.allSatisfy { $0.kind == .modified })
        let versions = try await f.store.checkpoints(vaultID: vault.id)
        XCTAssertEqual(versions[0].entries.first { $0.path == "build.py" }?.executable, true)
        XCTAssertFalse(versions[0].entries.contains { $0.path.contains(".planisphere-recovery") })
        for (index, path) in receipt.recoveryPaths.enumerated() {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), plan.changes[index].before)
        }
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("attachment.bin")), Data([0, 255, 1]))
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("excluded/keep.tex"), encoding: .utf8), "excluded\n")
        let reopened = try VaultStore(rootURL: f.storeURL)
        let receipts = try await reopened.mutationReceipts(vaultID: vault.id)
        XCTAssertEqual(receipts, [receipt])
        let replay = try await reopened.applyTextMutation(plan)
        XCTAssertEqual(replay, receipt)
        let restored = try await reopened.restoreCopy(vaultID: vault.id, checkpointID: receipt.beforeCheckpointID,
                                                      destination: f.base.appendingPathComponent("Recovered"))
        XCTAssertEqual(try Data(contentsOf: restored.url.appendingPathComponent("paper/main.tex")), original)
        XCTAssertEqual(try Data(contentsOf: restored.url.appendingPathComponent("attachment.bin")), Data([0, 255, 1]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: restored.url.appendingPathComponent("reference.tex").path), "paper/main.tex")
        let exported = try await reopened.exportVault(vaultID: vault.id, destination: f.base.appendingPathComponent("Export"))
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("files/paper/main.tex")), replacement)
    }

    func testStaleBytesModeLinkDirectoryAndSettingsRefuseBeforeWrites() async throws {
        for scenario in ["attachment", "new", "mode", "link", "directory", "settings"] {
            let f = try Fixture(); defer { f.clean() }
            let (vault, plan) = try await setup(f)
            switch scenario {
            case "attachment": try f.write("attachment.bin", Data([1, 2, 3]))
            case "new": try f.write("new.txt", "new")
            case "mode": XCTAssertEqual(chmod(f.source.appendingPathComponent("build.py").path, 0o600), 0)
            case "link":
                let link = f.source.appendingPathComponent("reference.tex")
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "other.tex")
            case "directory": try FileManager.default.removeItem(at: f.source.appendingPathComponent("empty"))
            default: try f.write(".planisphere/scope.json", #"{"excludedPaths":[]}"#)
            }
            await fails { try await f.store.applyTextMutation(plan) }
            XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("paper/main.tex")), original, scenario)
            let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
            XCTAssertTrue(receipts.isEmpty, scenario)
            let versions = try await f.store.checkpoints(vaultID: vault.id)
            XCTAssertEqual(versions.count, 1, scenario)
        }
    }

    func testUnsupportedBinaryHiddenSymlinkAndMalformedPlansRefuse() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        func make(_ changes: [TextMutation], entries: [FileEntry]? = nil, extensions: [String] = ["py", "tex"]) throws -> TextMutationPlan {
            try TextMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: plan.scope,
                expectedEntries: entries ?? plan.expectedEntries, extensions: extensions, changes: changes, reviewedPacket: Data())
        }
        XCTAssertThrowsError(try make(plan.changes, extensions: ["bin"]))
        XCTAssertThrowsError(try make(plan.changes, extensions: ["tex", "py"]))
        XCTAssertThrowsError(try make(plan.changes, entries: plan.expectedEntries + [plan.expectedEntries[0]]))
        XCTAssertThrowsError(try make([TextMutation(path: "paper/main.tex", before: original, after: Data([255]))]))
        XCTAssertThrowsError(try make([TextMutation(path: "paper/main.tex", before: original, after: Data([65, 0]))]))
        XCTAssertThrowsError(try make([TextMutation(path: "reference.tex", before: Data("paper/main.tex".utf8), after: replacement)]))
        let settings = try Data(contentsOf: f.source.appendingPathComponent(".planisphere/scope.json"))
        XCTAssertThrowsError(try make([TextMutation(path: ".planisphere/scope.json", before: settings, after: Data("{}".utf8))], extensions: ["json"]))
        XCTAssertThrowsError(try make([TextMutation(path: "excluded/keep.tex", before: Data("excluded\n".utf8), after: replacement)]))
        await fails { try await f.store.applyMarkdownMutation(plan.plan) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: VaultFormat.encode(plan)) as? [String: Any])
        var inner = try XCTUnwrap(object["plan"] as? [String: Any]); inner["digest"] = String(repeating: "0", count: 64); object["plan"] = inner
        let corrupt = try VaultFormat.decode(TextMutationPlan.self, from: JSONSerialization.data(withJSONObject: object))
        await fails { try await f.store.applyTextMutation(corrupt) }
        let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
        XCTAssertTrue(receipts.isEmpty)
    }

    func testInterruptionBlocksBothAPIsUntilRecoveryIsAcknowledged() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        await f.store.setMutationStepHook { index, phase in
            if index == 0 && phase == "afterExchange" { throw VaultStoreError.unavailable("Injected interruption") }
        }
        await fails { try await f.store.applyTextMutation(plan) }
        await f.store.setMutationStepHook(nil)
        let reopened = try VaultStore(rootURL: f.storeURL)
        let receipts = try await reopened.mutationReceipts(vaultID: vault.id)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.status, .interrupted)
        XCTAssertNil(receipt.afterCheckpointID)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.recoveryPaths[0])), original)
        let mdReview = try await reopened.checkpointPlan(vaultID: vault.id, mode: .markdownOnly)
        let md = try MarkdownMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: XCTUnwrap(mdReview.scope),
            expectedFiles: ["untouched.md": VaultFS.hash(Data("retained\n".utf8))],
            changes: [MarkdownMutation(path: "untouched.md", before: Data("retained\n".utf8), after: Data("updated\n".utf8))])
        await fails { try await reopened.applyMarkdownMutation(md) }
        await fails { try await reopened.applyTextMutation(plan) }
        _ = try await reopened.acknowledgeMutationRecovery(vaultID: vault.id, operationID: plan.id)
        await fails { try await reopened.applyTextMutation(plan) }
        let completed = try await reopened.applyMarkdownMutation(md)
        XCTAssertEqual(completed.status, .completed)
    }

    func testConcurrentEditsAndSymlinkRecoveryFolderPreserveEvidence() async throws {
        for scenario in ["beforeExchange", "exchangeBoundary", "afterCheckpoint", "recoverySymlink"] {
            let f = try Fixture(); defer { f.clean() }
            let (vault, plan) = try await setup(f)
            let target = f.source.appendingPathComponent("paper/main.tex")
            let attachment = f.source.appendingPathComponent("attachment.bin")
            let outside = f.base.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            if scenario == "recoverySymlink" {
                try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("paper/.planisphere-recovery"), withDestinationURL: outside)
            }
            await f.store.setMutationStepHook { index, phase in
                if index == 0 && phase == scenario { try Data("editor change".utf8).write(to: target) }
                if scenario == "afterCheckpoint" && phase == "beforeAfterCheckpoint" { try Data([8, 9]).write(to: attachment) }
            }
            await fails { try await f.store.applyTextMutation(plan) }
            let receipts = try await f.store.mutationReceipts(vaultID: vault.id)
            // A recovery symlink is caught by the pinned full inventory before writing.
            if scenario == "recoverySymlink" { XCTAssertTrue(receipts.isEmpty) }
            else {
                let receipt = try XCTUnwrap(receipts.first)
                XCTAssertEqual(receipt.status, .interrupted)
                XCTAssertNil(receipt.afterCheckpointID)
                if scenario == "exchangeBoundary" {
                    XCTAssertEqual(try String(contentsOfFile: receipt.recoveryPaths[0], encoding: .utf8), "editor change")
                }
                if scenario == "beforeExchange" {
                    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "editor change")
                }
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testDeletionRetainsOriginalAndEmptyDirectory() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let deletion = try TextMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: plan.scope,
            expectedEntries: plan.expectedEntries, extensions: ["tex"],
            changes: [TextMutation(path: "paper/main.tex", before: original, after: nil)], reviewedPacket: Data())
        let receipt = try await f.store.applyTextMutation(deletion)
        XCTAssertEqual(receipt.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("paper/main.tex").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.appendingPathComponent("paper").path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.recoveryPaths[0])), original)
    }

    func testTextCrashChildHelper() async throws {
        guard let root = ProcessInfo.processInfo.environment["PLANISPHERE_TEXT_CRASH_ROOT"],
              let path = ProcessInfo.processInfo.environment["PLANISPHERE_TEXT_CRASH_PLAN"] else { return }
        let store = try VaultStore(rootURL: URL(fileURLWithPath: root))
        let plan = try VaultFormat.decode(TextMutationPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        await store.setMutationStepHook { index, phase in
            if index == 0 && phase == "afterExchange" { _exit(74) }
        }
        _ = try await store.applyTextMutation(plan)
        XCTFail("Expected abrupt termination")
    }

    func testAbruptExitRetainsTextJournalAndRecoveryBytes() async throws {
        let f = try Fixture(); defer { f.clean() }
        let (vault, plan) = try await setup(f)
        let path = f.base.appendingPathComponent("text-review.json")
        try VaultFormat.encode(plan).write(to: path)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "PlanisphereCoreTests.TextMutationTests/testTextCrashChildHelper", Bundle(for: TextMutationTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PLANISPHERE_TEXT_CRASH_ROOT"] = f.storeURL.path
        environment["PLANISPHERE_TEXT_CRASH_PLAN"] = path.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 74)
        let reopened = try VaultStore(rootURL: f.storeURL)
        let receipts = try await reopened.mutationReceipts(vaultID: vault.id)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.status, .interrupted)
        XCTAssertNil(receipt.afterCheckpointID)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.recoveryPaths[0])), original)
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("paper/main.tex")), replacement)
        let restored = try await reopened.restoreCopy(vaultID: vault.id, checkpointID: receipt.beforeCheckpointID,
                                                      destination: f.base.appendingPathComponent("Crash recovery"))
        XCTAssertEqual(try Data(contentsOf: restored.url.appendingPathComponent("paper/main.tex")), original)
        await fails { try await reopened.applyTextMutation(plan) }
    }
}
