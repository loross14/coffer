import AppKit
import SwiftUI
import XCTest
@testable import PlanisphereApp

@MainActor
final class OnboardingSnapshotTests: XCTestCase {
    func testRenderSixSteps() throws {
        guard let folder = ProcessInfo.processInfo.environment["PLANISPHERE_ONBOARDING_SNAPSHOTS"] else { throw XCTSkip("Opt-in visual review") }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/private/tmp/onboarding-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = VaultAppModel(dataDirectory: root)
        let setup = model.onboarding
        setup.saved.destination = URL(fileURLWithPath: "/Users/you/World Knowledge")
        setup.saved.purpose = "A home for my research, writing and projects."
        for index in 0..<6 {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = OnboardingView(model: model, interactive: false).frame(width: 1120, height: 800)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 1120, height: 800)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance); window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("step-\(index + 1)-\(mode).png"))
            }
            switch index {
            case 0: setup.saved.progress.accountVerified(true)
            case 1:
                setup.saved.progress.agentVerified("claudeCode", successfulRun: true)
                setup.candidates = [.init(url: URL(fileURLWithPath: "/Users/you/Documents/Research")), .init(url: URL(fileURLWithPath: "/Users/you/Documents/Projects"))]
            case 2: setup.saved.progress.sourcesSelected([UUID(), UUID()])
            case 3: setup.saved.progress.confirmVaultSetup()
            case 4: setup.saved.progress.finishLocalModelChoice()
            default: break
            }
        }
    }
}
