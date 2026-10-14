import AppKit
import PlanisphereGrapheine
import SwiftUI
import XCTest
@testable import PlanisphereApp

final class MeasurePanelTests: XCTestCase {
    private func fixture() throws -> GraphMeasurement {
        let json = """
        {"schema":"grapheine-measure-v1","engine":"0.28.0","link_rule":"r","basis":"Graph measurements are heuristics computed from explicit links under LINK_RULE; they are not authority, truth, or source adequacy.",
         "vault":{"name":"v","roots":["/v"]},"graph":{"nodes":3,"edges":2},"gate":5000,
         "values":{"health":{"nodes":3,"edges":2,"mean_degree":1.33,"orphans":0,"isolates":0,"unresolved":1},
                   "degree":{"nodes":3,"edges":2,"mean":1.33,"median":1,"max":2,"histogram":{"1":2,"2":1},"top":[{"path":"a/hub.md","degree":2}]},
                   "components":{"components":1,"largest":3,"isolates":0},"spectrum":{"nodes":3,"components":1,"fiedler":1.0,"reading":"healthy connectivity"}},
         "skipped":{},"timings":{},"elapsed":0.1,"measured_at":"t","vaultPath":"/v","scannedAt":"t","scope":{"kind":"markdown-discovery","appliedFilters":[],"excludedCount":0,"excludedPaths":[],"limitations":[],"truncated":false,"unsupportedFilters":[]},"fingerprint":"abcdef0123","noteCount":3}
        """
        return try JSONDecoder().decode(GraphMeasurement.self, from: Data(json.utf8))
    }

    func testShapeSentenceReadsTheCounts() throws {
        let m = try fixture()
        XCTAssertEqual(MeasurePanel.shapeSentence(m), "One connected piece · no orphans · 1 unresolved link.")
        XCTAssertEqual(MeasurePanel.detailRows(m).first?.0, "Components · isolates")
    }

    /// Opt-in: renders the panel from a real measurement to a PNG for design review.
    /// PLANISPHERE_MEASURE_FIXTURE=<bridge measure json> PLANISPHERE_RENDER_OUT=<png path>
    @MainActor func testRenderPanelForReview() throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixturePath = env["PLANISPHERE_MEASURE_FIXTURE"], let out = env["PLANISPHERE_RENDER_OUT"] else { throw XCTSkip("set PLANISPHERE_MEASURE_FIXTURE and PLANISPHERE_RENDER_OUT") }
        let m = try JSONDecoder().decode(GraphMeasurement.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let dark = env["PLANISPHERE_RENDER_LIGHT"] == nil
        let panel = MeasurePanel(measurement: m, measuring: false, error: nil, onMeasure: {}, onSelect: { _ in })
            .padding(20).frame(width: 316).background(PSStyle.surface)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: panel)
        renderer.scale = 2
        var image: NSImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        let nsImage = try XCTUnwrap(image)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(nsImage.tiffRepresentation)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
        XCTAssertGreaterThan(png.count, 10_000)
    }
}
