import XCTest
import Foundation
import Darwin
@testable import PlanisphereCore

/// The message for a folder that will not open must say what actually stopped it.
final class VaultFolderErrorTests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PlanisphereFolderTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func message(_ url: URL) -> String {
        do { _ = try VaultFS.directory(url); return "" }
        catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    func testSymbolicLinkComponentIsNamedAsSuch() throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Inside"), withIntermediateDirectories: true)
        let link = base.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let text = message(link.appendingPathComponent("Inside"))
        XCTAssertTrue(text.contains("symbolic link") && text.contains("“Alias”"), text)
        XCTAssertFalse(text.contains("Privacy"), text)
    }

    func testUnreadableFolderPointsAtMacOSFilePermissions() throws {
        try XCTSkipIf(getuid() == 0, "root ignores folder permissions")
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let locked = base.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: locked.appendingPathComponent("Enge"), withIntermediateDirectories: true)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { chmod(locked.path, 0o700) }
        let text = message(locked.appendingPathComponent("Enge"))
        XCTAssertTrue(text.contains("Privacy & Security") && text.contains("“Desktop”"), text)
        XCTAssertFalse(text.contains("symbolic link"), text)
    }

    func testMissingFolderSaysWhichPartIsMissing() throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let text = message(base.appendingPathComponent("Nowhere/Deeper"))
        XCTAssertTrue(text.contains("does not exist") && text.contains("“Nowhere”"), text)
    }

    func testRegularFileComponentIsNotCalledAPermissionProblem() throws {
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("note.md")
        try Data("x\n".utf8).write(to: file)
        let text = message(file.appendingPathComponent("Inside"))
        XCTAssertTrue(text.contains("not a folder") && text.contains("“note.md”"), text)
    }

    func testReadableVaultInsideSearchOnlyParentCanRegisterAndCheckpoint() async throws {
        try XCTSkipIf(getuid() == 0, "root ignores folder permissions")
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("PrivateParent", isDirectory: true)
        let vaultURL = parent.appendingPathComponent("SelectedVault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try Data("selected evidence\n".utf8).write(to: vaultURL.appendingPathComponent("note.md"))
        let store = try VaultStore(rootURL: base.appendingPathComponent("History"))
        XCTAssertEqual(chmod(parent.path, 0o100), 0)
        defer { chmod(parent.path, 0o700) }

        // The OS permits reading this selected folder without listing its parent.
        let direct = Darwin.open(vaultURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(direct, 0)
        if direct >= 0 { Darwin.close(direct) }
        let parentRead = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertEqual(parentRead, -1)
        if parentRead >= 0 { Darwin.close(parentRead) }

        let vault = try await store.register(url: vaultURL)
        let checkpoint = try await store.createCheckpoint(vaultID: vault.id, message: "Selected folder")
        let text = try await store.text(vaultID: vault.id, checkpointID: checkpoint.id, path: "note.md")
        XCTAssertEqual(text, "selected evidence\n")
    }

    func testDeniedVaultRemainsDeniedAndCanBeRetriedAfterPermissionRestored() async throws {
        try XCTSkipIf(getuid() == 0, "root ignores folder permissions")
        let base = try temporary(); defer { try? FileManager.default.removeItem(at: base) }
        let vaultURL = base.appendingPathComponent("SelectedVault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let store = try VaultStore(rootURL: base.appendingPathComponent("History"))
        XCTAssertEqual(chmod(vaultURL.path, 0), 0)
        defer { chmod(vaultURL.path, 0o700) }
        do {
            _ = try await store.register(url: vaultURL)
            XCTFail("An unreadable selected vault must not be registered")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SelectedVault"))
        }
        let deniedRecords = try await store.vaults()
        XCTAssertTrue(deniedRecords.isEmpty)
        XCTAssertEqual(chmod(vaultURL.path, 0o700), 0)
        _ = try await store.register(url: vaultURL)
        let recoveredRecords = try await store.vaults()
        XCTAssertEqual(recoveredRecords.count, 1)
    }
}
