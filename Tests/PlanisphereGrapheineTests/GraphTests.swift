import Foundation
import Darwin
import XCTest
@testable import PlanisphereGrapheine

final class GraphTests: XCTestCase, @unchecked Sendable {
    func testRealBridgeGraphReadsOnlySelectedMarkdownScopeAndReturnsNoBodies() async throws {
        let fixture = try temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for folder in ["Notes", "Other", "Ignored", ".planisphere"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let body = "[[Notes/Target]] [[Target]] [[Missing]] [relative](Notes/Target.md) `[[Other/Target]]`\n"
        try Data(body.utf8).write(to: fixture.appendingPathComponent("Read.md"))
        try Data("# PRIVATE NOTE BODY\n".utf8).write(to: fixture.appendingPathComponent("Notes/Target.md"))
        try Data().write(to: fixture.appendingPathComponent("Other/Target.md"))
        try Data("[[Read]]".utf8).write(to: fixture.appendingPathComponent("Ignored/Hidden.md"))
        try Data(#"{"excludedPaths":["Ignored/"]}"#.utf8).write(to: fixture.appendingPathComponent(".planisphere/scope.json"))
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("linked.md"), withDestinationURL: fixture.appendingPathComponent("Read.md"))

        let graph = try await GrapheineService().graph(vaultURL: fixture)
        XCTAssertEqual(graph.vaultPath, fixture.path)
        XCTAssertEqual(Set(graph.nodes.map(\.id)), ["Read.md", "Notes/Target.md", "Other/Target.md"])
        XCTAssertEqual(graph.edges, [GraphEdge(source: "Read.md", target: "Notes/Target.md")])
        XCTAssertEqual(graph.ambiguousLinkCount, 1)
        XCTAssertEqual(graph.unresolvedLinkCount, 1)
        XCTAssertEqual(graph.nodes.first(where: { $0.id == "Read.md" })?.outDegree, 1)
        XCTAssertTrue(graph.scope.excludedPaths.contains("Ignored/"))
        XCTAssertTrue(graph.scope.excludedPaths.contains("linked.md"))
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("Read.md"), encoding: .utf8), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git").path))
    }

    func testEmptyGraphIsValidAndNotAnEngineFailure() throws {
        let vault = URL(fileURLWithPath: "/private/tmp/graph-fixture")
        var report = report(vault: vault)
        report["nodes"] = []
        report["edges"] = []
        report["totalNodeCount"] = 0
        report["totalEdgeCount"] = 0
        let graph = try decode(report, vault: vault)
        XCTAssertTrue(graph.nodes.isEmpty)
        XCTAssertTrue(graph.edges.isEmpty)
    }

    func testGraphRejectsUnsafePathsDuplicateNodesAndConnectionsAndFalseDegrees() throws {
        let vault = URL(fileURLWithPath: "/private/tmp/graph-fixture")
        let a = node("A.md", incoming: 0, outgoing: 1)
        let b = node("B.md", incoming: 1, outgoing: 0)
        let edge = ["source": "A.md", "target": "B.md"]
        let changes: [[String: Any]] = [
            ["vaultPath": "/private/tmp/another"],
            ["nodes": [a, a]],
            ["edges": [edge, edge], "totalEdgeCount": 2],
            ["edges": [["source": "A.md", "target": "Missing.md"]]],
            ["nodes": [node("../A.md", incoming: 0, outgoing: 0), b]],
            ["nodes": [node("A.png", incoming: 0, outgoing: 0), b]],
            ["nodes": [node("A.md", incoming: 99, outgoing: 1), b]],
            ["omittedNodeCount": 1],
            ["omittedEdgeCount": -1],
            ["totalNodeCount": 20_001, "omittedNodeCount": 19_999],
            ["unresolvedLinkCount": -1],
            ["limits": Array(repeating: "limit", count: 101)]
        ]
        _ = try decode(report(vault: vault), vault: vault)
        for change in changes {
            var altered = report(vault: vault)
            altered.merge(change) { _, new in new }
            XCTAssertThrowsError(try decode(altered, vault: vault), "Accepted invalid graph: \(change)")
        }
    }

    func testReturnedGraphLimitAndScopeClaimsAreValidated() throws {
        let vault = URL(fileURLWithPath: "/private/tmp/graph-fixture")
        var altered = report(vault: vault)
        altered["nodes"] = (0..<10_001).map { node("N\($0).md", incoming: 0, outgoing: 0) }
        altered["totalNodeCount"] = 10_001
        XCTAssertThrowsError(try decode(altered, vault: vault))
        for scopeChange: [String: Any] in [["kind": "whole-vault"], ["excludedPaths": ["../outside/"], "excludedCount": 1],
                                          ["excludedCount": 1, "truncated": false]] {
            altered = report(vault: vault)
            var scope = try XCTUnwrap(altered["scope"] as? [String: Any])
            scope.merge(scopeChange) { _, new in new }
            altered["scope"] = scope
            XCTAssertThrowsError(try decode(altered, vault: vault))
        }
    }

    func testCancellingGraphStopsItsReadSubprocess() async throws {
        let fixture = try temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let engine = fixture.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: false)
        try Data().write(to: engine.appendingPathComponent("grapheine_authority.py"))
        let helper = fixture.appendingPathComponent("helper.py")
        try Data("""
        import os
        from pathlib import Path
        import tempfile
        import time
        stage = Path(tempfile.mkdtemp())
        (stage / 'private-note.md').write_text('fixture note bytes')
        Path(__file__).with_suffix('.workdir').write_text(os.environ['TMPDIR'])
        Path(__file__).with_suffix('.pid').write_text(str(os.getpid()))
        time.sleep(30)
        """.utf8).write(to: helper)
        let service = GrapheineService(helperURL: helper, engineURL: engine, pythonURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let task = Task { try await service.graph(vaultURL: fixture) }
        let pidFile = helper.deletingPathExtension().appendingPathExtension("pid")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let workdir = try String(contentsOf: helper.deletingPathExtension().appendingPathExtension("workdir"), encoding: .utf8)
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled graph must not return a snapshot")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertEqual(kill(pid, 0), -1, "The cancelled read subprocess must exit")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workdir), "Cancelling must remove the private staged note bytes")
    }

    private func temporary() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("planisphere-graph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func node(_ path: String, incoming: Int, outgoing: Int) -> [String: Any] {
        ["id": path, "title": String(path.split(separator: "/").last!.dropLast(3)),
         "folder": path.split(separator: "/").dropLast().joined(separator: "/"),
         "degree": incoming + outgoing, "inDegree": incoming, "outDegree": outgoing]
    }

    private func report(vault: URL) -> [String: Any] {
        ["vaultPath": vault.path, "scannedAt": "2026-10-10T12:00:00+00:00",
         "nodes": [node("A.md", incoming: 0, outgoing: 1), node("B.md", incoming: 1, outgoing: 0)],
         "edges": [["source": "A.md", "target": "B.md"]],
         "totalNodeCount": 2, "totalEdgeCount": 1, "omittedNodeCount": 0, "omittedEdgeCount": 0,
         "unresolvedLinkCount": 0, "ambiguousLinkCount": 0, "unsupportedLinkCount": 0, "limits": [],
         "scope": ["kind": "markdown-discovery", "excludedPaths": [], "excludedCount": 0,
                   "truncated": false, "appliedFilters": [], "unsupportedFilters": [], "limitations": []] as [String: Any]]
    }

    private func decode(_ report: [String: Any], vault: URL) throws -> GraphSnapshot {
        try GrapheineService.validatedGraph(JSONSerialization.data(withJSONObject: report), vaultURL: vault)
    }
}
