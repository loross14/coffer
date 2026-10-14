import AppKit
import AuthenticationServices
import Observation
import PlanisphereConnection

@MainActor @Observable
final class ConsoleConnectionModel: NSObject, ASWebAuthenticationPresentationContextProviding {
    // Enable only after the matching server routes have been deployed and verified.
    static var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "PlanisphereConsoleConnectionEnabled") as? Bool == true
    }
    static let consoleURL = ConsoleClient.production.appendingPathComponent("console")
    var presented = false
    private(set) var credential: ConnectionCredential?
    private(set) var busy = false
    private(set) var verified = false
    private(set) var needsSignIn = false
    private(set) var message: String?
    private var loaded = false
    private var session: ASWebAuthenticationSession?
    private let client: ConsoleClient
    private let keychain: any ConnectionCredentialStoring
    private let authenticate: (@MainActor (URL) async throws -> URL)?

    init(client: ConsoleClient = ConsoleClient(), keychain: any ConnectionCredentialStoring = ConnectionKeychain(),
         authenticate: (@MainActor (URL) async throws -> URL)? = nil) {
        self.client = client
        self.keychain = keychain
        self.authenticate = authenticate
        super.init()
    }

    var title: String { credential?.connection.workspace.name ?? "Connect to Console" }
    var canCancelSignIn: Bool { session != nil }

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
            let callback: URL
            if let authenticate {
                callback = try await authenticate(url)
            } else {
                callback = try await withCheckedThrowingContinuation { continuation in
                    let authentication = ASWebAuthenticationSession(url: url, callbackURLScheme: "ooo.planisphere.mac",
                                                                    completionHandler: Self.completion(continuation))
                    authentication.presentationContextProvider = self
                    authentication.prefersEphemeralWebBrowserSession = false
                    session = authentication
                    if !authentication.start() {
                        session = nil
                        continuation.resume(throwing: ConnectionError.unavailable)
                    }
                }
            }
            let code = try attempt.code(from: callback)
            let saved = try await client.exchange(code, attempt: attempt)
            // Keep a returned credential in memory even if Keychain refuses the save,
            // so the user can revoke it instead of losing the only local handle.
            credential = saved; verified = true; needsSignIn = false
            try keychain.save(saved)
            message = "Connected. Your vaults and history stay on this Mac."
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            message = "Connection cancelled. Your local vaults are ready to use."
        } catch { message = error.localizedDescription }
        session = nil; busy = false
    }

    // The session can call back off the main thread (seen with a non-Safari default browser).
    // A closure formed inside this main-actor class would assert main-actor isolation and crash.
    nonisolated static func completion(_ continuation: CheckedContinuation<URL, Error>) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            if let url { continuation.resume(returning: url) }
            else { continuation.resume(throwing: error ?? ConnectionError.invalidResponse) }
        }
    }

    func cancel() { session?.cancel() }

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

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
