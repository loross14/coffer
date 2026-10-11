import Foundation
import XCTest
@testable import PlanisphereGrapheine

final class DocumentTests: XCTestCase, @unchecked Sendable {
    func testRealMixedGraphSearchAndSourceReadPreserveOriginals() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("planisphere-documents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["Read.md": "[Implementation](model.py) [Manuscript](main.tex)",
                     "main.tex": "\\section{Main}\\label{main}\n\\input{chapter}\nSee \\ref{proof}",
                     "chapter.tex": "\\section{Proof}\\label{proof}\nSecondline theoremneedle",
                     "model.py": "# First line\nanswer = 'codeneedle'\n",
                     "ignored.tex": "do not admit secretneedle"]
        for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".planisphere"), withIntermediateDirectories: true)
        try Data(#"{"pathPrefixes":["ignored"]}"#.utf8).write(to: root.appendingPathComponent(".planisphere/scope.json"))
        let service = GrapheineService()
        let graph = try await service.graph(vaultURL: root, includeDocuments: true)
        XCTAssertEqual(Set(graph.nodes.map(\.id)), ["Read.md", "main.tex", "chapter.tex", "model.py"])
        XCTAssertTrue(graph.edges.contains(GraphEdge(source: "Read.md", target: "model.py")))
        XCTAssertTrue(graph.edges.contains(GraphEdge(source: "main.tex", target: "chapter.tex")))
        let result = try await service.searchDocuments(vaultURL: root, query: "codeneedle", includeDocuments: true)
        XCTAssertEqual(result.matches.map(\.path), ["model.py"])
        XCTAssertEqual(result.matches.first?.location.line, 2)
        let read = try await service.readDocument(vaultURL: root, path: "model.py", location: result.matches.first?.location, includeDocuments: true)
        XCTAssertEqual(read.body, "answer = 'codeneedle'\n")
        XCTAssertEqual(read.representation, "original_text")
        do {
            _ = try await service.readDocument(vaultURL: root, path: "ignored.tex", includeDocuments: true)
            XCTFail("Exact reads must preserve exclusions")
        } catch {}
        do {
            _ = try await service.readDocument(vaultURL: root, path: "model.py")
            XCTFail("Default mode must remain Markdown")
        } catch {}
        for (path, text) in files { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), text) }
    }
}
