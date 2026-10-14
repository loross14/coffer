import AppKit
import Observation
import PlanisphereConnection

@MainActor @Observable
final class ConsoleConnectionModel {
    // Enable only after the matching server routes have been deployed and verified.
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "PlanisphereConsoleConnectionEnabled") as? Bool == true
    }
    static let consoleURL = ConsoleClient.production.appendingPathComponent("console")
    static let browserPreferenceKey = "ConsoleSignInBrowser"
    var presented = false
    private(set) var credential: ConnectionCredential?
    private(set) var busy = false
    private(set) var verified = false
    private(set) var needsSignIn = false
    private(set) var message: String?
    private(set) var browsers: [SignInBrowser] = []
    var chosenBrowserID: String? { didSet { defaults.set(chosenBrowserID, forKey: Self.browserPreferenceKey) } }
    private var loaded = false
    private var pending: (handoff: CallbackHandoff, attempt: ConnectionAttempt)?
    private var expiry: Task<Void, Never>?
    private let client: ConsoleClient
    private let keychain: any ConnectionCredentialStoring
    private let defaults: UserDefaults
    private let findBrowsers: @MainActor () -> [SignInBrowser]
    private let open: @MainActor (URL, SignInBrowser?) async throws -> Void
    private let signInTimeout: Duration

    // The server keeps a sign-in request for 20 minutes.
    init(client: ConsoleClient = ConsoleClient(), keychain: any ConnectionCredentialStoring = ConnectionKeychain(),
         defaults: UserDefaults = .standard,
         findBrowsers: @escaping @MainActor () -> [SignInBrowser] = { SignInBrowser.installed() },
         open: @escaping @MainActor (URL, SignInBrowser?) async throws -> Void = { try await SignInBrowser.open($0, in: $1) },
         signInTimeout: Duration = .seconds(20 * 60)) {
        self.client = client
        self.keychain = keychain
        self.defaults = defaults
        self.findBrowsers = findBrowsers
        self.open = open
        self.signInTimeout = signInTimeout
        chosenBrowserID = defaults.string(forKey: Self.browserPreferenceKey)
    }

    var title: String { credential?.connection.workspace.name ?? "Connect to Console" }
    var canCancelSignIn: Bool { pending != nil }
    // The chosen browser, or the system default when none was chosen or it is no longer installed.
    var browser: SignInBrowser? { browsers.first { $0.id == chosenBrowserID } ?? browsers.first }

    func refreshBrowsers() { browsers = findBrowsers() }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do { credential = try keychain.read() }
        catch { message = error.localizedDescription; loaded = false; return }
        if credential != nil { await refresh() }
    }

    func connect() async {
        guard !busy, credential == nil else { return }
        busy = true; message = nil
        do {
            let attempt = try ConnectionAttempt()
            let url = try await client.begin(attempt)
            if browsers.isEmpty { refreshBrowsers() }
            let browser = browser
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                let handoff = CallbackHandoff(continuation)
                pending = (handoff, attempt)
                expiry = Task { [signInTimeout] in
                    try? await Task.sleep(for: signInTimeout)
                    if !Task.isCancelled { handoff.finish(.failure(ConnectionSignInError.expired)) }
                }
                Task {
                    do { try await open(url, browser) } catch { handoff.finish(.failure(error)) }
                }
            }
            pending = nil
            let code = try attempt.code(from: callback)
            let saved = try await client.exchange(code, attempt: attempt)
            // Keep a returned credential in memory even if Keychain refuses the save,
            // so the user can revoke it instead of losing the only local handle.
            credential = saved; verified = true; needsSignIn = false
            try keychain.save(saved)
            message = "Connected. Your vaults and history stay on this Mac."
        } catch { message = error.localizedDescription }
        expiry?.cancel(); expiry = nil; pending = nil; busy = false
    }

    // The console returns through the ooo.planisphere.mac:/console-connected link, which the browser
    // opens and the app receives through onOpenURL. Accept it only for the pending attempt's state;
    // the exchange still requires that attempt's PKCE verifier.
    func receiveCallback(_ url: URL) -> Bool {
        guard let pending, (try? pending.attempt.code(from: url)) != nil else { return false }
        pending.handoff.finish(.success(url))
        return true
    }

    func cancel() { pending?.handoff.finish(.failure(ConnectionSignInError.cancelled)) }

    func refresh() async {
        guard !busy, var value = credential else { return }
        busy = true; message = nil
        do {
            value.connection = try await client.status(value.token)
            credential = value; verified = true; needsSignIn = false
            try keychain.save(value)
            message = "Connection checked. Your vaults and history stay on this Mac."
        } catch {
            verified = false
            needsSignIn = (error as? ConnectionError) == .signInAgain
            message = error.localizedDescription
        }
        busy = false
    }

    func disconnect() async {
        guard !busy, let value = credential else { return }
        busy = true; message = nil
        do {
            try await client.disconnect(value.token)
            verified = false
            try keychain.remove()
            credential = nil; needsSignIn = false
            message = "Disconnected. Your vaults and history remain on this Mac."
        } catch {
            message = "Disconnect did not finish. The saved connection is kept so you can retry. " + error.localizedDescription
        }
        busy = false
    }

    func switchWorkspace() async {
        guard !busy else { return }
        await disconnect()
        guard credential == nil else { return }
        await connect()
    }

    func reconnect() async {
        guard !busy, needsSignIn else { return }
        await disconnect()
        // Keep the existing credential if revocation fails, so it remains retryable.
        guard credential == nil else { return }
        await connect()
    }
}

// Finishes a sign-in exactly once: the return link, Cancel or the expiry, whichever comes first.
final class CallbackHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }

    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
