import AppKit
import PlanisphereCore
import SwiftUI
import XCTest
@testable import PlanisphereApp

/// The graph follows the vault: notes written after the first load (an import, an agent, a
/// checkpoint restore) show up without pressing Refresh. Uses the real bridge on a small vault.
final class GraphAutoRefreshTests: XCTestCase {
    private func makeVault(notes: Int) throws -> URL {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PlanisphereGraphRefresh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try write(notes: 0..<notes, into: base)
        return base
    }

    private func write(notes: Range<Int>, into vault: URL) throws {
        for index in notes {
            let next = "note-\((index + 1) % max(notes.upperBound, 1))"
            try Data("# Note \(index)\n\nSee [[\(next)]].\n".utf8).write(to: vault.appendingPathComponent("note-\(index).md"))
        }
    }

    @MainActor
    private func wait(_ seconds: TimeInterval, until condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    func testNotesWrittenAfterLoadRefreshTheGraphOnce() async throws {
        let vaultURL = try makeVault(notes: 3)
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let vault = VaultRecord(name: "Pax", path: vaultURL.path)
        let graph = VaultGraphModel()

        await graph.load(vault: vault)
        XCTAssertNil(graph.error)
        XCTAssertEqual(graph.snapshot?.nodes.count, 3)
        XCTAssertEqual(graph.visibleCounts.notes, 3)
        let before = try XCTUnwrap(graph.snapshot)
        let render = ProcessInfo.processInfo.environment["PLANISPHERE_RENDER_OUT"].map(URL.init(fileURLWithPath:))
        if let render { try renderGraph(vault: vault, graph: graph, to: render.appendingPathComponent("graph-before-import.png")) }
        graph.watch(vault: vault)

        // An "import": several notes land at once, plus editor state that must not count.
        try FileManager.default.createDirectory(at: vaultURL.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: vaultURL.appendingPathComponent(".obsidian/workspace.json"))
        try write(notes: 3..<8, into: vaultURL)

        await wait(20) { graph.snapshot?.nodes.count == 8 && !graph.loading }
        XCTAssertEqual(graph.snapshot?.nodes.count, 8, "the graph picked up the five new notes on its own")
        XCTAssertEqual(graph.visibleCounts.notes, 8)
        XCTAssertGreaterThan(graph.snapshot?.edges.count ?? 0, before.edges.count)
        XCTAssertEqual(graph.automaticRefreshes, 1, "one burst of writes is one refresh")
        XCTAssertNil(graph.error)
        if let render { try renderGraph(vault: vault, graph: graph, to: render.appendingPathComponent("graph-after-import.png")) }

        // Quiet vault: nothing further happens.
        await wait(3) { graph.automaticRefreshes > 1 }
        XCTAssertEqual(graph.automaticRefreshes, 1)
        graph.stop()
    }

    @MainActor
    func testChangesDuringALoadQueueExactlyOneMoreLoad() async throws {
        let vaultURL = try makeVault(notes: 2)
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let vault = VaultRecord(name: "Pax", path: vaultURL.path)
        let graph = VaultGraphModel()
        await graph.load(vault: vault)
        XCTAssertEqual(graph.snapshot?.nodes.count, 2)

        graph.vaultChanged(vault: vault)
        XCTAssertTrue(graph.loading, "a change notice starts a load at once, so later notices queue behind it")
        try write(notes: 2..<4, into: vaultURL)
        graph.vaultChanged(vault: vault)
        graph.vaultChanged(vault: vault)
        graph.vaultChanged(vault: vault)
        await wait(20) { graph.snapshot?.nodes.count == 4 && !graph.loading }
        XCTAssertEqual(graph.snapshot?.nodes.count, 4)
        XCTAssertEqual(graph.automaticRefreshes, 2, "three change notices during one load collapse into one follow-up load")
    }

    /// Hosts the real graph view offscreen and writes a PNG for design review (opt-in via PLANISPHERE_RENDER_OUT).
    @MainActor
    private func renderGraph(vault: VaultRecord, graph: VaultGraphModel, to file: URL) throws {
        let size = NSSize(width: 1180, height: 720)
        let host = NSHostingView(rootView: VaultGraphView(vault: vault, graph: graph).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let settle = Date().addingTimeInterval(1.5)
        while Date() < settle { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 20_000)
        window.contentView = nil
    }
}
