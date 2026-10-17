import XCTest
@testable import PlanisphereCore

final class OnboardingProgressTests: XCTestCase {
    func testExistingVaultsMustPrecedeKnowledgeCreation() throws {
        var progress = OnboardingProgress()
        let source = UUID(), world = UUID()
        XCTAssertFalse(progress.knowledgeCreated(world, consented: true, verified: true))
        XCTAssertFalse(progress.accountVerified(false))
        XCTAssertTrue(progress.accountVerified(true))
        XCTAssertFalse(progress.agentVerified("claudeCode", successfulRun: false))
        XCTAssertTrue(progress.agentVerified("claudeCode", successfulRun: true))
        XCTAssertEqual(progress.step, .existingVaults)
        progress.confirmVaultSetup()
        XCTAssertEqual(progress.step, .existingVaults)
        progress.sourcesSelected([source, source])
        XCTAssertEqual(progress.sourceVaultIDs, [source])
        XCTAssertEqual(progress.step, .vaultSetup)
        progress.confirmVaultSetup()
        progress.finishLocalModelChoice()
        XCTAssertFalse(progress.knowledgeCreated(world, consented: false, verified: true))
        XCTAssertFalse(progress.knowledgeCreated(world, consented: true, verified: false))
        XCTAssertTrue(progress.knowledgeCreated(world, consented: true, verified: true))
        XCTAssertEqual(progress.worldKnowledgeVaultID, world)
        XCTAssertEqual(progress.step, .complete)
        let restored = try JSONDecoder().decode(OnboardingProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(restored, progress)
    }

    func testPeopleWithoutExistingVaultsCanContinue() {
        var progress = OnboardingProgress()
        progress.accountVerified(true)
        progress.agentVerified("codex", successfulRun: true)
        progress.sourcesSelected([])
        XCTAssertEqual(progress.step, .vaultSetup)
        XCTAssertTrue(progress.sourceVaultIDs.isEmpty)
    }
}
