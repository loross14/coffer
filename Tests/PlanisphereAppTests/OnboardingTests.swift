import XCTest
@testable import PlanisphereApp

@MainActor
final class OnboardingTests: XCTestCase {
    func testDiscoverySelectionErrorsAndResume() throws {
        let root = URL(fileURLWithPath: "/private/tmp/onboarding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("obsidian.json")
        try Data(#"{"vaults":{"a":{"path":"/private/tmp/Notes"},"b":{"path":"/private/tmp/Notes"},"c":{"path":"/private/tmp/Work"}}}"#.utf8).write(to: registry)
        let model = OnboardingModel(root: root)
        model.load(existing: [])
        XCTAssertTrue(model.visible)
        model.discover(existing: [], registryURL: registry)
        XCTAssertEqual(model.candidates.count, 2)
        model.candidates[0].selected = false
        model.discover(existing: [], registryURL: registry)
        XCTAssertFalse(model.candidates[0].selected)
        model.accountVerified(true)
        model.saved.agent = AgentHost.codex.rawValue
        model.saved.verificationStarted = Date()
        XCTAssertTrue(model.persist())
        let resumed = OnboardingModel(root: root)
        resumed.load(existing: [])
        XCTAssertEqual(resumed.step, .agent)
        XCTAssertEqual(resumed.selectedAgent, .codex)
        XCTAssertFalse(resumed.consent)
        try Data("broken".utf8).write(to: registry)
        resumed.discover(existing: [], registryURL: registry)
        XCTAssertNotNil(resumed.message)
    }
    func testInstallAndOldHookCannotVerifyConnection() {
        let model = OnboardingModel(root: URL(fileURLWithPath: "/private/tmp/unused-onboarding-test"))
        model.saved.verificationStarted = Date()
        XCTAssertFalse(model.verifiedAgent(.init(status: "installed")))
        let old = AgentHostReport.LastRun(at: Date().addingTimeInterval(-120), action: "resume", exitCode: 0)
        XCTAssertFalse(model.verifiedAgent(.init(status: "installed", lastRun: old)))
        let fresh = AgentHostReport.LastRun(at: Date(), action: "resume", exitCode: 0)
        XCTAssertTrue(model.verifiedAgent(.init(status: "installed", lastRun: fresh)))
        XCTAssertFalse(model.verifiedAgent(.init(status: "installed", problem: "Broken hook", lastRun: fresh)))
    }
}
