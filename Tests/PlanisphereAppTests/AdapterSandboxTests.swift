import XCTest
@testable import PlanisphereApp

@MainActor
final class AdapterSandboxTests: XCTestCase {
    func waitForResult(_ model: AdapterSandboxModel) async throws {
        for _ in 0..<200 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Sandbox did not finish")
    }
    func testRealRunnerAndNonzeroExitAreVisible() async throws {
        let model = AdapterSandboxModel()
        model.executable = "/bin/sh"
        model.arguments = "[\"-c\",\"cat; exit 7\"]"
        model.input = "test-only"
        model.run("execute")
        try await waitForResult(model)
        XCTAssertEqual(model.status, "Run needs attention")
        XCTAssertTrue(model.result.contains("test-only"))
        XCTAssertTrue(model.result.contains("\"exit_code\" : 7"))
    }
    func testCancellationFinishesAndAllowsNextRun() async throws {
        let model = AdapterSandboxModel()
        model.executable = "/bin/sleep"; model.arguments = "[\"20\"]"
        model.run("execute")
        try await Task.sleep(for: .milliseconds(200))
        model.cancel()
        try await waitForResult(model)
        XCTAssertEqual(model.status, "Canceled")
        model.run("fixture")
        try await waitForResult(model)
        XCTAssertEqual(model.status, "Envelope checked")
    }
    func testInvalidArgumentsFailWithoutStartingProcess() {
        let model = AdapterSandboxModel()
        model.arguments = "{}"; model.run("execute")
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.status, "Check input")
        XCTAssertTrue(model.result.contains("array of strings"))
    }
}
