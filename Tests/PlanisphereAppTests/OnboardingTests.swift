import XCTest
import PlanisphereCore
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
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/onboarding-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func sourcesModel(_ root: URL) -> OnboardingModel {
        let model = OnboardingModel(root: root)
        model.load(existing: [])
        model.saved.progress.accountVerified(true)
        model.saved.progress.agentVerified("codex", successfulRun: true)
        return model
    }
    func testManualSourcesAndDeselectionSurviveRestartAndRediscovery() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("registry.json")
        let discovered = root.appendingPathComponent("Discovered")
        let manual = root.appendingPathComponent("Manual")
        let data = try JSONSerialization.data(withJSONObject: ["vaults": ["a": ["path": discovered.path]]])
        try data.write(to: registry)
        let model = sourcesModel(root)
        model.discover(existing: [], registryURL: registry)
        model.selectSource(id: discovered.path, selected: false)
        model.addFolders([manual, manual.appendingPathComponent("../Manual")])
        let resumed = sourcesModel(root)
        resumed.discover(existing: [], registryURL: registry)
        XCTAssertEqual(resumed.candidates.count, 2)
        XCTAssertFalse(try XCTUnwrap(resumed.candidates.first { $0.id == discovered.path }).selected)
        XCTAssertTrue(try XCTUnwrap(resumed.candidates.first { $0.id == manual.path }).selected)
    }
    func testPartialFailurePersistsAndRetryKeepsSourceIdentity() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let recordA = VaultRecord(name: "A", path: a.path), recordB = VaultRecord(name: "B", path: b.path)
        let model = sourcesModel(root); model.addFolders([a, b])
        await model.registerSources { url in
            if url == b { throw CocoaError(.fileReadNoPermission) }
            return recordA
        }
        XCTAssertEqual(model.step, .existingVaults)
        let resumed = OnboardingModel(root: root); resumed.load(existing: [recordA])
        XCTAssertEqual(resumed.candidates.first { $0.id == a.path }?.registeredID, recordA.id)
        XCTAssertNotNil(resumed.candidates.first { $0.id == b.path }?.error)
        resumed.discover(existing: [recordA], registryURL: root.appendingPathComponent("missing.json"))
        await resumed.registerSources { $0 == a ? recordA : recordB }
        XCTAssertEqual(resumed.step, .vaultSetup)
        XCTAssertEqual(Set(resumed.saved.progress.sourceVaultIDs), Set([recordA.id, recordB.id]))
        let final = OnboardingModel(root: root); final.load(existing: [recordA, recordB])
        XCTAssertTrue(final.candidates.allSatisfy { $0.error == nil && $0.registeredID != nil })
    }
    func testRegistrationUsesSnapshotAndStableIdentityWhenCandidatesReorder() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let records = [VaultRecord(name: "A", path: a.path), VaultRecord(name: "B", path: b.path)]
        let model = sourcesModel(root); model.addFolders([a, b])
        var calls: [URL] = []
        await model.registerSources { url in
            XCTAssertTrue(model.busy)
            if calls.isEmpty {
                model.selectSource(id: a.path, selected: false)
                model.addFolders([root.appendingPathComponent("Unexpected")])
                model.discover(existing: [], registryURL: root.appendingPathComponent("missing"))
                XCTAssertEqual(model.candidates.map(\.url), [a, b])
                XCTAssertTrue(model.candidates.allSatisfy(\.selected))
                // Simulate an internal update bypassing the UI while registration suspends.
                model.candidates.reverse()
                await Task.yield()
            }
            calls.append(url)
            return records.first { $0.path == url.path }!
        }
        XCTAssertEqual(calls, [a, b])
        for record in records { XCTAssertEqual(model.candidates.first { $0.id == record.path }?.registeredID, record.id) }
        XCTAssertEqual(model.step, .vaultSetup)
    }
    func testInFlightSelectionOrRemovalDoesNotAdvanceOrMisattribute() async throws {
        for remove in [false, true] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
            let model = sourcesModel(root); model.addFolders([a, b])
            await model.registerSources { url in
                if url == a {
                    if remove { model.candidates.removeFirst() } else { model.candidates[0].selected = false }
                    await Task.yield()
                }
                return VaultRecord(name: url.lastPathComponent, path: url.path)
            }
            XCTAssertEqual(model.step, .existingVaults)
            XCTAssertTrue(model.saved.progress.sourceVaultIDs.isEmpty)
            XCTAssertNotNil(model.message)
            let resumed = OnboardingModel(root: root); resumed.load(existing: [])
            XCTAssertEqual(resumed.candidates, model.candidates)
        }
    }
    func testCanonicalRegistrationPathKeepsRequestedSourceIdentity() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let requested = root.appendingPathComponent("Notes")
        let canonical = VaultRecord(name: "Notes", path: root.appendingPathComponent("notes").path)
        let model = sourcesModel(root); model.addFolders([requested])
        await model.registerSources { url in
            XCTAssertEqual(url, requested)
            return canonical
        }
        XCTAssertEqual(model.candidates.first?.id, requested.path)
        XCTAssertEqual(model.candidates.first?.registeredID, canonical.id)
        XCTAssertEqual(model.step, .vaultSetup)
        model.selectSource(id: requested.path, selected: false)
        let resumed = OnboardingModel(root: root); resumed.load(existing: [canonical])
        resumed.discover(existing: [canonical], registryURL: root.appendingPathComponent("missing"))
        XCTAssertEqual(resumed.candidates.count, 1)
        XCTAssertEqual(resumed.candidates.first?.id, requested.path)
        XCTAssertEqual(resumed.candidates.first?.selected, false)
    }
    func testOlderSavedSetupWithoutCandidatesStillLoads() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = sourcesModel(root); XCTAssertTrue(model.persist())
        let state = root.appendingPathComponent("onboarding.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        object.removeValue(forKey: "candidates")
        try JSONSerialization.data(withJSONObject: object).write(to: state)
        let resumed = OnboardingModel(root: root); resumed.load(existing: [])
        XCTAssertEqual(resumed.step, .existingVaults)
        XCTAssertTrue(resumed.candidates.isEmpty)
        XCTAssertNil(resumed.message)
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

@MainActor
extension OnboardingTests {
    private var existingHealthyAgent: AgentHostReport {
        .init(status: "installed", lastRun: .init(at: Date().addingTimeInterval(-86400), action: "resume", exitCode: 0))
    }
    func testLegacyVaultUserGetsRecoveryAndKeepsAccountAgentAndFolders() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let record = VaultRecord(name: "Research", path: root.appendingPathComponent("Research").path)
        let model = OnboardingModel(root: root); model.load(existing: [record])
        XCTAssertTrue(model.visible)
        XCTAssertEqual(model.candidates.first?.registeredID, record.id)
        model.reconcile(accountVerified: true, reports: [.codex: existingHealthyAgent], reportingConnected: false)
        XCTAssertEqual(model.step, .existingVaults)
        XCTAssertEqual(model.saved.progress.connectedAgent, AgentHost.codex.rawValue)
        await model.registerSources(existing: [record]) { _ in
            XCTFail("Already registered folders must not be registered again")
            return record
        }
        XCTAssertEqual(model.step, .vaultSetup)
        let resumed = OnboardingModel(root: root); resumed.load(existing: [record])
        XCTAssertEqual(resumed.step, .vaultSetup)
        XCTAssertEqual(resumed.saved.progress.sourceVaultIDs, [record.id])
    }
    func testMissingAccountDoesNotLoseExistingAgentAndClaudeReportingIsSeparate() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OnboardingModel(root: root); model.load(existing: [])
        model.reconcile(accountVerified: false, reports: [.claudeCode: existingHealthyAgent], reportingConnected: true)
        XCTAssertEqual(model.step, .account)
        model.reconcile(accountVerified: true, reports: [.claudeCode: existingHealthyAgent], reportingConnected: false)
        XCTAssertEqual(model.step, .agent)
        model.reconcile(accountVerified: true, reports: [.claudeCode: existingHealthyAgent], reportingConnected: true)
        XCTAssertEqual(model.step, .existingVaults)
    }
    func testRecoveryRejectsBrokenUnknownAndFailedAgentsAndPreservesFreshRunRequirement() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = OnboardingModel(root: root); model.load(existing: [])
        var report = existingHealthyAgent
        report.problem = "Hook target missing"
        model.reconcile(accountVerified: true, reports: [.codex: report], reportingConnected: true)
        XCTAssertEqual(model.step, .agent)
        report = existingHealthyAgent; report.lastRun?.exitCode = 1
        XCTAssertFalse(model.canReuseAgent(report))
        XCTAssertFalse(model.canReuseAgent(.unknown))
        XCTAssertFalse(model.canReuseAgent(.init(status: "installed")))
        model.saved.verificationStarted = Date()
        model.reconcile(accountVerified: true, reports: [.codex: existingHealthyAgent], reportingConnected: true)
        XCTAssertEqual(model.step, .agent)
    }
    func testLegacyExistingKnowledgeCompletesWithoutRecreatingButSavedWizardKeepsItsIntent() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let world = VaultRecord(name: "My renamed home", path: root.appendingPathComponent("Home").path)
        let model = OnboardingModel(root: root); model.load(existing: [world])
        model.reconcile(accountVerified: true, reports: [.codex: existingHealthyAgent], reportingConnected: false,
                        knowledge: world, knowledgeSources: [])
        XCTAssertEqual(model.step, .complete); XCTAssertFalse(model.visible)
        XCTAssertEqual(model.saved.destination, world.url)
        let resumed = OnboardingModel(root: root); resumed.load(existing: [world])
        XCTAssertEqual(resumed.step, .complete); XCTAssertFalse(resumed.visible)
        let other = try fixture(); defer { try? FileManager.default.removeItem(at: other) }
        let wizard = sourcesModel(other)
        wizard.reconcile(accountVerified: true, reports: [:], reportingConnected: true, knowledge: world)
        XCTAssertEqual(wizard.step, .existingVaults)
    }
    func testInstalledOptionalModelIsNotRequestedAgainAndChoicesRemain() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = sourcesModel(root)
        model.saved.progress.sourcesSelected([]); model.saved.progress.confirmVaultSetup()
        model.saved.purpose = "My chosen purpose"
        model.reconcile(accountVerified: true, reports: [:], reportingConnected: true, localModelInstalled: true)
        XCTAssertEqual(model.step, .worldKnowledge)
        XCTAssertEqual(model.saved.purpose, "My chosen purpose")
    }
}

@MainActor
extension OnboardingTests {
    func testLegacyStartupOpensRecoveryBeforeSelectingAndLoadingHistory() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try VaultStore(rootURL: root.appendingPathComponent("State"))
        let record = try await store.register(url: source)
        let model = VaultAppModel(dataDirectory: root.appendingPathComponent("State"))
        await model.start()
        XCTAssertTrue(model.onboarding.visible)
        XCTAssertEqual(model.vaults.map(\.id), [record.id])
        XCTAssertNil(model.selectedVaultID, "History is deferred until the user opens the workspace")
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
    }
}
