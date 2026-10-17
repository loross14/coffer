import AppKit
import PlanisphereModel
import SwiftUI
import XCTest
@testable import PlanisphereApp

/// Opt-in (PLANISPHERE_SNAPSHOT_DIR=/absolute/folder): renders the Local tab in its main states,
/// light and dark, as PNG files for design review.
@MainActor
final class LocalModelsSnapshotTests: XCTestCase {
    func testRenderLocalTabStates() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLANISPHERE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set PLANISPHERE_SNAPSHOT_DIR to render review screenshots")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let spec = ModelSpec.builtIn
        let location = ModelLocation(directory: URL(fileURLWithPath: "/Users/you/Library/Application Support/Planisphere/Models"))
        let record = try JSONDecoder().decode(RuntimeRecord.self, from: Data("""
            {"version":1,"identifier":"\(spec.identifier)","name":"\(spec.name)","model":"\(spec.modelKey)","endpoint":"\(spec.endpoint)",
             "path":"\(location.modelFile(spec).path)","sha256":"\(spec.sha256)","sizeBytes":\(spec.sizeBytes),"contextLength":\(spec.contextLength)}
            """.utf8))
        let observing = SupportStatus(enabled: true, mode: "observe", model: spec.identifier,
                                      models: [SupportModelChoice(id: spec.identifier, name: spec.name)],
                                      retrieval_connections: 1, linked_connections: 1, issue: nil)
        let states: [(String, (ModelRuntimeModel) -> Void, CGFloat)] = [
            ("running", { $0.preview(.running, record: record, reply: .init(
                text: "Checkpoints let you return to a known-good moment without losing what you have now.", seconds: 0.41, tokens: 21), agentHooks: 1) }, 900),
            ("install", { $0.preview(.notInstalled, record: nil, existingCopy: URL(fileURLWithPath: "/tmp/copy.gguf")) }, 640),
            ("downloading", { $0.preview(.installing("Downloading…", 0.42), record: nil) }, 640),
        ]
        for (name, configure, height) in states {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let support = LocalSupportModel(root: URL(fileURLWithPath: "/tmp/planisphere-snapshot/Memory"))
                support.preview(observing)
                let runtime = ModelRuntimeModel(location: location)
                configure(runtime)
                let view = LocalModelsView(runtime: runtime, support: support, open: { _ in })
                    .frame(width: 900, height: height)
                try render(view, size: NSSize(width: 900, height: height), appearance: appearance,
                           to: output.appendingPathComponent("local-\(name)-\(mode).png"))
            }
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
