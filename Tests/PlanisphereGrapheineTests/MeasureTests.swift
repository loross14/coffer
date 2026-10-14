import Foundation
import XCTest
@testable import PlanisphereGrapheine

final class MeasureTests: XCTestCase, @unchecked Sendable {
    func testRealBridgeMeasureReadsScopedMarkdownAndBindsToTheScan() async throws {
        let fixture = try temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for folder in ["old", "Ignored", ".planisphere"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("[[old/01-genesis|Genesis]] [[02-exodus]] [[Missing]]\n".utf8).write(to: fixture.appendingPathComponent("CANON.md"))
        try Data("[[CANON]]\n".utf8).write(to: fixture.appendingPathComponent("old/01-genesis.md"))
        try Data("[[CANON]] [[01-genesis]]\n".utf8).write(to: fixture.appendingPathComponent("old/02-exodus.md"))
        try Data("[[CANON]]\n".utf8).write(to: fixture.appendingPathComponent("Ignored/Hidden.md"))
        try Data(#"{"excludedPaths":["Ignored/"]}"#.utf8).write(to: fixture.appendingPathComponent(".planisphere/scope.json"))

        let service = GrapheineService()
        let measurement = try await service.measure(vaultURL: fixture, gate: 0, top: 3)
        XCTAssertEqual(measurement.schema, "grapheine-measure-v1")
        XCTAssertEqual(measurement.vaultPath, fixture.path)
        XCTAssertEqual(measurement.graph.nodes, 3)
        XCTAssertEqual(measurement.graph.edges, 3)
        XCTAssertEqual(measurement.values.health?.unresolved, 1)
        XCTAssertEqual(measurement.values.degree?.top.first?.path, "CANON.md")
        XCTAssertEqual(measurement.values.components?.components, 1)
        XCTAssertNotNil(measurement.values.spectrum?.fiedler)
        XCTAssertTrue(measurement.skipped.isEmpty)
        XCTAssertFalse(measurement.basis.isEmpty)
        XCTAssertTrue(measurement.scope.excludedPaths.contains("Ignored/"))
        let graph = try await service.graph(vaultURL: fixture)
        let undirected = Set(graph.edges.map { Set([$0.source, $0.target]) })
        XCTAssertEqual(graph.nodes.count, measurement.graph.nodes, "graph view and measurement see the same notes")
        XCTAssertEqual(undirected.count, measurement.graph.edges, "graph view and measurement count the same links once direction is folded")
        XCTAssertEqual(graph.unresolvedLinkCount, measurement.values.health?.unresolved)
        let gated = try await service.measure(vaultURL: fixture, gate: 2)
        XCTAssertNotNil(gated.skipped["spectrum"])
        XCTAssertNotNil(gated.values.health)
    }

    func testMeasurementValidationRejectsOtherVaultsAndBadSchemas() throws {
        let vault = URL(fileURLWithPath: "/private/tmp/measure-fixture")
        var document = fixture(vault: vault)
        XCTAssertNoThrow(try decode(document, vault: vault))
        document["vaultPath"] = "/private/tmp/other"
        XCTAssertThrowsError(try decode(document, vault: vault))
        document = fixture(vault: vault); document["schema"] = "grapheine-measure-v0"
        XCTAssertThrowsError(try decode(document, vault: vault))
        document = fixture(vault: vault); document["fingerprint"] = "short"
        XCTAssertThrowsError(try decode(document, vault: vault))
        document = fixture(vault: vault)
        var values = document["values"] as! [String: Any]
        values["degree"] = ["nodes": 2, "edges": 1, "mean": 1.0, "median": 1, "max": 1, "top": [["path": "../escape.md", "degree": 1]]]
        document["values"] = values
        XCTAssertThrowsError(try decode(document, vault: vault))
    }

    private func temporary() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("planisphere-measure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fixture(vault: URL) -> [String: Any] {
        ["schema": "grapheine-measure-v1", "engine": "0.29.0", "link_rule": "rule", "basis": "heuristics",
         "vault": ["name": "measure-fixture", "roots": [vault.path]], "graph": ["nodes": 2, "edges": 1], "gate": 5000,
         "values": ["health": ["nodes": 2, "edges": 1, "mean_degree": 1.0, "orphans": 1, "isolates": 0, "unresolved": 0]] as [String: Any],
         "skipped": [:] as [String: String], "timings": ["health": 0.01], "elapsed": 0.02, "measured_at": "2026-10-13T00:00:00+00:00",
         "vaultPath": vault.path, "scannedAt": "2026-10-13T00:00:00+00:00",
         "scope": ["kind": "markdown-discovery", "excludedPaths": [], "excludedCount": 0, "truncated": false,
                   "appliedFilters": [], "unsupportedFilters": [], "limitations": []] as [String: Any],
         "fingerprint": String(repeating: "ab", count: 32), "noteCount": 2]
    }

    private func decode(_ document: [String: Any], vault: URL) throws -> GraphMeasurement {
        try GrapheineService.validatedMeasurement(JSONSerialization.data(withJSONObject: document), vaultURL: vault)
    }
}
