import AppKit
import XCTest
@testable import PlanisphereApp

@MainActor final class TerminalWorkspaceTests: XCTestCase {
    func testLaunchConfigurationRejectsMissingDirectoryAndDoesNotInjectAppSecrets() throws {
        let directory = FileManager.default.temporaryDirectory
        let config = try TerminalLaunchConfiguration(directory: directory, environment: [
            "PLANISPHERE_API_KEY": "sentinel", "AWS_SECRET_ACCESS_KEY": "sentinel", "PATH": "/usr/bin:/bin"
        ])
        XCTAssertFalse(config.environment.contains { $0.contains("sentinel") })
        XCTAssertTrue(config.environment.contains("TERM=xterm-256color"))
        XCTAssertThrowsError(try TerminalLaunchConfiguration(directory: directory.appendingPathComponent(UUID().uuidString)))
    }

    func testRealPTYInputDirectoryResizeInterruptAndExit() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Terminal test ' \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = TerminalSession(configuration: try TerminalLaunchConfiguration(directory: directory, shell: "/bin/zsh"), arguments: ["-f"])
        defer { session.close() }
        XCTAssertTrue(session.view.process.running)
        session.view.send(txt: "pwd > directory.txt; test -t 0 && printf 'pty-ok' > tty.txt\n")
        try await waitFor { FileManager.default.fileExists(atPath: directory.appendingPathComponent("tty.txt").path) }
        let actualDirectory = URL(fileURLWithPath: try String(contentsOf: directory.appendingPathComponent("directory.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(try actualDirectory.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject, try directory.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tty.txt"), encoding: .utf8), "pty-ok")
        session.view.setFrameSize(NSSize(width: 650, height: 350))
        session.view.send(txt: "sleep 30\n")
        try await Task.sleep(for: .milliseconds(200))
        session.view.send(txt: "\u{03}")
        session.view.send(txt: "printf 'after-interrupt' > interrupted.txt\n")
        try await waitFor { FileManager.default.fileExists(atPath: directory.appendingPathComponent("interrupted.txt").path) }
        session.view.send(txt: "exit 7\n")
        try await waitFor { session.ended }
        XCTAssertFalse(session.view.process.running)
        XCTAssertEqual(session.exitCode, 7)
    }

    func testExplicitCloseReapsProcessAndPreservesOtherSession() async throws {
        _ = NSApplication.shared
        let a = TerminalSession(configuration: try TerminalLaunchConfiguration(directory: FileManager.default.temporaryDirectory, shell: "/bin/zsh"), arguments: ["-f"])
        let b = TerminalSession(configuration: try TerminalLaunchConfiguration(directory: FileManager.default.temporaryDirectory, shell: "/bin/zsh"), arguments: ["-f"])
        defer { a.close(); b.close() }
        let pid = a.view.process.shellPid
        a.close()
        try await waitFor { kill(pid, 0) != 0 }
        XCTAssertTrue(b.view.process.running)
        XCTAssertTrue(a.ended)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Terminal did not reach the expected state within five seconds")
    }
}
