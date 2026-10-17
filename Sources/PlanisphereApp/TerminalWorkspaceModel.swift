import AppKit
import Foundation
import Observation
import SwiftTerm

struct TerminalLaunchConfiguration {
    let directory: URL
    let shell: String
    let environment: [String]

    init(directory: URL, shell requestedShell: String? = nil, environment source: [String: String] = ProcessInfo.processInfo.environment) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        self.directory = directory
        let configured = requestedShell ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        shell = FileManager.default.isExecutableFile(atPath: configured) ? configured : "/bin/zsh"
        // The shell may load the user's own profile. Never inject the app's cloud credentials.
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = source[key] { env[key] = value }
        }
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["SHELL"] = shell
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "Planisphere"
        environment = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}

@MainActor @Observable
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let initialDirectory: URL
    var title: String
    private(set) var ended = false
    private(set) var closing = false
    private(set) var exitCode: Int32?
    let view: LocalProcessTerminalView

    init(configuration: TerminalLaunchConfiguration, arguments: [String] = ["-l"]) {
        initialDirectory = configuration.directory
        title = configuration.directory.lastPathComponent
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        super.init()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.processDelegate = self
        view.startProcess(executable: configuration.shell, args: arguments, environment: configuration.environment,
                          currentDirectory: configuration.directory.path)
        if !view.process.running { ended = true }
    }

    func close() {
        guard !ended, !closing else { return }
        closing = true
        let pid = view.process.shellPid
        guard pid > 0 else { ended = true; return }
        let foreground = tcgetpgrp(view.process.childfd)
        if foreground > 0, foreground != getpgrp() { kill(-foreground, SIGHUP) }
        kill(pid, SIGHUP)
        // Keep the process monitor alive until it reaps the child. SwiftTerm's
        // terminate() cancels it immediately, which otherwise leaves a zombie.
        Task { @MainActor [self] in
            for _ in 0..<20 {
                if ended { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !ended, view.process.running { kill(pid, SIGKILL) }
            for _ in 0..<20 {
                if ended { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            view.terminate()
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in self?.title = String(title.filter { !$0.isNewline && !$0.isASCIIControl }.prefix(80)) }
    }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in self?.ended = true; self?.exitCode = exitCode.map { status in
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : 128 + signal
        } }
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}

@MainActor @Observable
final class TerminalWorkspaceModel {
    static let shared = TerminalWorkspaceModel()
    private(set) var sessions: [TerminalSession] = []
    var selectedID: UUID?
    var error: String?
    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }
    var runningCount: Int { sessions.filter { !$0.ended }.count }

    func open(directory: URL) {
        guard sessions.count < 8 else { error = "Close a terminal before opening another. You can keep up to eight tabs."; return }
        do {
            let session = TerminalSession(configuration: try TerminalLaunchConfiguration(directory: directory))
            sessions.append(session); selectedID = session.id
        } catch { self.error = "Could not open this folder: \(error.localizedDescription)" }
    }

    func close(_ session: TerminalSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = sessions.last?.id }
    }

    func closeAll() { for session in sessions { session.close() }; sessions = []; selectedID = nil }
}

@MainActor
final class TerminalApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRelocationModel().offerIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = TerminalWorkspaceModel.shared
        if store.runningCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Close running terminals and quit?"
            alert.informativeText = "Your \(store.runningCount) running terminal session(s) will close. Commands still running may be interrupted."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Close Terminals and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        let adapters = AdapterSandboxModel.shared
        if adapters.busy { adapters.cancel() }
        let running = store.sessions.filter { !$0.ended }
        store.closeAll()
        guard !running.isEmpty || adapters.busy else { return .terminateNow }
        Task { @MainActor in
            for _ in 0..<45 {
                if running.allSatisfy({ $0.ended }) && !adapters.busy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
