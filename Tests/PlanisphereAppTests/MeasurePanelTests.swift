import AppKit
import PlanisphereGrapheine
import SwiftUI
import XCTest
@testable import PlanisphereApp

final class MeasurePanelTests: XCTestCase {
    private func fixture(orphans: Int = 0, unresolved: Int = 1, components: Int = 1) throws -> GraphMeasurement {
        let json = """
        {"schema":"grapheine-measure-v1","engine":"0.28.0","link_rule":"r","basis":"Graph measurements are heuristics computed from explicit links under LINK_RULE; they are not authority, truth, or source adequacy.",
         "vault":{"name":"v","roots":["/v"]},"graph":{"nodes":3,"edges":2},"gate":5000,
         "values":{"health":{"nodes":3,"edges":2,"mean_degree":1.33,"orphans":\(orphans),"isolates":0,"unresolved":\(unresolved)},
                   "degree":{"nodes":3,"edges":2,"mean":1.33,"median":1,"max":2,"histogram":{"1":2,"2":1},"top":[{"path":"a/hub.md","degree":2}]},
                   "components":{"components":\(components),"largest":3,"isolates":0},"spectrum":{"nodes":3,"components":1,"fiedler":1.0,"reading":"healthy connectivity"}},
         "skipped":{},"timings":{},"elapsed":0.1,"measured_at":"t","vaultPath":"/v","scannedAt":"t","scope":{"kind":"markdown-discovery","appliedFilters":[],"excludedCount":0,"excludedPaths":[],"limitations":[],"truncated":false,"unsupportedFilters":[]},"fingerprint":"abcdef0123","noteCount":3}
        """
        return try JSONDecoder().decode(GraphMeasurement.self, from: Data(json.utf8))
    }

    func testShapeSentenceReadsTheCounts() throws {
        let m = try fixture()
        XCTAssertEqual(MeasurePanel.shapeSentence(m), "One connected piece · no orphans · 1 unresolved link.")
        XCTAssertEqual(MeasurePanel.detailRows(m).first?.0, "Components · isolates")
    }

    func testLargeVaultsKeepTheHistogramAxisAndRatiosReadable() throws {
        XCTAssertEqual(MeasurePanel.labeledBins(8), Set(0..<8), "small histograms label every bin")
        let many = MeasurePanel.labeledBins(30)
        XCTAssertLessThanOrEqual(many.count, 7, "about six labels plus the last, so two-digit labels never wrap")
        XCTAssertTrue(many.contains(0) && many.contains(29))
        XCTAssertEqual(MeasurePanel.ratio(66_391.0 / 199_990_000), "0.00033", "a sparse vault doesn't read 0.000")
        XCTAssertEqual(MeasurePanel.ratio(0.0476), "0.048")
        let large = try fixture(orphans: 1177, unresolved: 973, components: 15)
        XCTAssertEqual(MeasurePanel.shapeSentence(large), "15 separate pieces · 1,177 orphans · 973 unresolved links.")
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
