import XCTest
import Foundation
import Darwin
@testable import PlanisphereCore

final class CheckpointScopeTests: XCTestCase {
    func testNativeScopeDoesNotReadLegacyApplicationSettings() throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        try f.write(".obsidian/app.json", "malformed legacy settings")
        try f.write(".planisphere/scope.json", #"{"excludedPaths":["private/"]}"#)
        try f.write("private/hidden.md", "hidden")
        try f.write("visible.md", "visible")
        let source = try VaultFS.directory(f.source)
        let plan = try CheckpointScopePlanner.plan(source: source, mode: .markdownOnly)
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertEqual(try XCTUnwrap(plan.scope).version, 4)
        XCTAssertTrue(try XCTUnwrap(plan.scope).excludes("private/hidden.md", isDirectory: false))
    }

    func testPlanPreservesSettingsAndAssetsWhileReportingExcludedRoots() throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        try f.write(".planisphere/scope.json", #"{"excludedPaths":["checkout/","linked-checkout/","private.md","*.tmp",99]}"#)
        try f.write(".planisphere/plugins/plugin/data.json", "settings")
        try f.write(".planisphere/plugins/plugin/.state/settings.json", "hidden settings")
        try f.write(".planisphere/plugins/plugin/node_modules/helper/data.json", "plugin settings dependency")
        try f.write("note.md", "note")
        try f.write("attachments/photo.bin", Data([0, 255, 1]))
        try f.write("private.md", "explicitly excluded")
        try f.write("checkout/keep.md", "excluded checkout")
        try f.write(".build/derived.md", "hidden")
        try f.write("node_modules/package/readme.md", "dependency")
        try f.write("cache.tmp", "unsupported filter keeps this")
        let external = f.base.appendingPathComponent("unreadable-target")
        XCTAssertEqual(mkfifo(external.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("reference"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("linked-checkout"), withDestinationURL: external)
        let source = try VaultFS.directory(f.source)
        let plan = try CheckpointScopePlanner.plan(source: source, mode: .vaultContent)
        XCTAssertEqual(plan.fileCount, 7)
        XCTAssertEqual(plan.symbolicLinkCount, 1)
        XCTAssertEqual(plan.excludedPathCount, 5)
        XCTAssertEqual(Set(plan.excludedPaths.map(\.path)), Set([".build", "checkout", "linked-checkout", "node_modules", "private.md"]))
        XCTAssertEqual(plan.unsupportedFilters.count, 2)
        XCTAssertFalse(try XCTUnwrap(plan.scope).excludes(".planisphere", isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: f.source.appendingPathComponent("note.md")), Data("note".utf8))
    }

    func testFrozenRulesRejectConfigurationChangesEvenWhenConfigurationIsExcluded() throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        try f.write(".planisphere/scope.json", #"{"excludedPaths":[".planisphere/"]}"#)
        let source = try VaultFS.directory(f.source)
        let scope = try CheckpointScope.load(source).scope
        try scope.verifySource(source)
        try f.write(".planisphere/scope.json", #"{"excludedPaths":[".planisphere/","notes/"]}"#)
        XCTAssertThrowsError(try scope.verifySource(source))
    }

    func testContentScopeDoesNotReadSymbolicSettingsOrSilentlyDiscardSpecialFiles() throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        try f.write(".planisphere/keep", "")
        let pipe = f.base.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent(".planisphere/scope.json"), withDestinationURL: pipe)
        let source = try VaultFS.directory(f.source)
        XCTAssertThrowsError(try CheckpointScopePlanner.plan(source: source, mode: .vaultContent))
        try FileManager.default.removeItem(at: f.source.appendingPathComponent(".planisphere/scope.json"))
        XCTAssertEqual(mkfifo(f.source.appendingPathComponent("live-pipe").path, 0o600), 0)
        XCTAssertThrowsError(try CheckpointScopePlanner.plan(source: source, mode: .vaultContent))
        XCTAssertThrowsError(try CheckpointScopePlanner.plan(source: source, mode: .wholeFolder))
    }

    func testManifestScopeValidationRejectsTraversalAndUnknownRulesVersion() throws {
        let traversal = CheckpointScope(excludedPaths: ["../outside/"], sourceConfigurationSHA256: nil)
        XCTAssertThrowsError(try traversal.validate())
        let unknown = try JSONDecoder().decode(CheckpointScope.self, from: Data(#"{"version":99,"excludedPaths":[]}"#.utf8))
        XCTAssertThrowsError(try unknown.validate())
    }
}
