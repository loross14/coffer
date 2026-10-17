import XCTest
@testable import PlanisphereCore

final class WorldKnowledgeTests: XCTestCase, @unchecked Sendable {
    func testSourcesScopeProvenanceHistoryAndResume() async throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        try f.write("One.md", "# One\n\nA useful original fact.\n## Next steps\nOriginal qualifications.")
        try f.write("private/Secret.md", "PRIVATE")
        try f.write("hidden/Secret.md", "FILTERED")
        try f.write(".secret.md", "HIDDEN")
        try f.write(".planisphere/scope.json", #"{"excludedPaths":["private/"],"pathPrefixes":["hidden/"]}"#)
        try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("Link.md").path, withDestinationPath: f.source.appendingPathComponent("private/Secret.md").path)
        let source = try await f.store.register(url: f.source)
        let destination = f.base.appendingPathComponent("World Knowledge"), operation = UUID()
        let world = try await f.store.createWorldKnowledge(at: destination, sources: [source.id], purpose: "", operationID: operation, consented: true)
        let receipt = try JSONDecoder().decode(WorldKnowledgeReceipt.self, from: Data(contentsOf: destination.appendingPathComponent("World-Knowledge.json")))
        XCTAssertEqual(receipt.evidence.map(\.path), ["One.md"])
        XCTAssertEqual(receipt.evidence.first?.root, f.source.path)
        XCTAssertEqual(receipt.schema, "planisphere.world-knowledge/1")
        XCTAssertEqual(receipt.evidence.first?.topics, ["Next steps", "One"])
        XCTAssertEqual(receipt.evidence.first?.originalID.count, 64)
        XCTAssertEqual(receipt.coverage.first?.indexedNotes, 1)
        XCTAssertEqual(receipt.coverage.first?.excludedPaths, ["hidden/", "private/"])
        let map = try String(contentsOf: destination.appendingPathComponent("Source-\(source.id.uuidString).md"), encoding: .utf8)
        XCTAssertTrue(map.contains("A useful original fact.")); XCTAssertTrue(map.contains("Next steps"))
        XCTAssertFalse(map.contains("PRIVATE")); XCTAssertFalse(map.contains("FILTERED"))
        let history = try await f.store.checkpoints(vaultID: world.id)
        XCTAssertEqual(history.count, 1)
        let resumed = try await f.store.createWorldKnowledge(at: destination, sources: [source.id], purpose: "", operationID: operation, consented: true)
        XCTAssertEqual(world.id, resumed.id)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("One.md"), encoding: .utf8), "# One\n\nA useful original fact.\n## Next steps\nOriginal qualifications.")
    }

    func testNoConsentNoEmptyTemplateAndNoOverwrite() async throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        let destination = f.base.appendingPathComponent("World Knowledge"), operation = UUID()
        for consent in [false, true] {
            do {
                _ = try await f.store.createWorldKnowledge(at: destination, sources: [], purpose: "", operationID: operation, consented: consent)
                XCTFail("An empty or unconsented creation must fail")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        _ = try await f.store.createWorldKnowledge(at: destination, sources: [], purpose: "Learn astronomy", operationID: operation, consented: true)
        try Data("My edited knowledge".utf8).write(to: destination.appendingPathComponent("Start Here.md"))
        do {
            _ = try await f.store.createWorldKnowledge(at: destination, sources: [], purpose: "", operationID: operation, consented: true)
            XCTFail("A changed map must not be silently accepted or overwritten")
        } catch {}
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Start Here.md"), encoding: .utf8), "My edited knowledge")
    }

    func testUnreadableOrUnsupportedSourceFailsWithoutPublishing() async throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        try f.write("One.md", "# Hello\ncontent")
        try f.write(".planisphere/scope.json", #"{"pathPrefixes":["*.md"]}"#)
        let source = try await f.store.register(url: f.source)
        let destination = f.base.appendingPathComponent("World Knowledge")
        do {
            _ = try await f.store.createWorldKnowledge(at: destination, sources: [source.id], purpose: "", operationID: UUID(), consented: true)
            XCTFail("Unsupported scope must fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

extension WorldKnowledgeTests {
    func testRoutingAliasesKeepOriginalIdentityAndQualifications() {
        let id = UUID()
        let source = WorldKnowledgeReceipt.Source(vaultID: id, root: "/Research", path: "Orbital motion.md", sha256: String(repeating: "a", count: 64), text: "---\naliases: [Orbits, 'Kepler']\ntopics:\n  - Astronomy\n  - Motion\n---\n# Orbital motion\n## Periods\nA qualified observation.", modifiedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(source.aliases, ["Kepler", "Orbits"])
        XCTAssertTrue(source.topics.contains("Astronomy"))
        XCTAssertTrue(source.topics.contains("Periods"))
        XCTAssertTrue(source.authority.contains("unassessed"))
        XCTAssertTrue(source.freshness.contains("snapshot"))
        let changed = WorldKnowledgeReceipt.Source(vaultID: id, root: "/Research", path: "Orbital motion.md", sha256: String(repeating: "b", count: 64), text: "# Revised title", modifiedAt: Date())
        XCTAssertEqual(source.originalID, changed.originalID)
        XCTAssertNotEqual(source.sha256, changed.sha256)
    }
}

extension WorldKnowledgeTests {
    func testRecognizesExistingManagedHomeAfterUserEditsWithoutCreatingHistory() async throws {
        let f = try VaultStoreTests.Fixture(); defer { f.clean() }
        let source = try await f.store.register(url: f.source)
        let absent = try await f.store.existingWorldKnowledge()
        XCTAssertNil(absent)
        let destination = f.base.appendingPathComponent("Knowledge")
        let world = try await f.store.createWorldKnowledge(at: destination, sources: [source.id], purpose: "Learning", operationID: UUID(), consented: true)
        try Data("# My edited home".utf8).write(to: destination.appendingPathComponent("Start Here.md"))
        let recovered = try await f.store.existingWorldKnowledge()
        XCTAssertEqual(recovered?.vault.id, world.id)
        XCTAssertEqual(recovered?.sources, [source.id])
        let checkpoints = try await f.store.checkpoints(vaultID: world.id)
        XCTAssertEqual(checkpoints.count, 1)
        try FileManager.default.removeItem(at: destination.appendingPathComponent("Start Here.md"))
        let missing = try await f.store.existingWorldKnowledge()
        XCTAssertNil(missing)
    }
}
