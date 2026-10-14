import AppKit
import UniformTypeIdentifiers

// A browser the console sign-in can open in. Browsers are apps that open both web links and HTML files.
struct SignInBrowser: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let isDefault: Bool

    // The system default browser comes first, then the rest by name.
    @MainActor static func installed(workspace: NSWorkspace = .shared) -> [SignInBrowser] {
        let link = URL(string: "https://www.planisphere.ooo")!
        let html = Set(workspace.urlsForApplications(toOpen: .html).map(\.standardizedFileURL))
        let preferred = workspace.urlForApplication(toOpen: link).flatMap { Bundle(url: $0)?.bundleIdentifier }
        var seen = Set<String>()
        let browsers = workspace.urlsForApplications(toOpen: link).compactMap { url -> SignInBrowser? in
            guard html.contains(url.standardizedFileURL), let id = Bundle(url: url)?.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return SignInBrowser(id: id, name: url.deletingPathExtension().lastPathComponent, url: url, isDefault: id == preferred)
        }
        return browsers.sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
    }

    @MainActor static func open(_ link: URL, in browser: SignInBrowser?) async throws {
        guard let browser else {
            guard NSWorkspace.shared.open(link) else { throw ConnectionSignInError.browserUnavailable(nil) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do { _ = try await NSWorkspace.shared.open([link], withApplicationAt: browser.url, configuration: configuration) }
        catch { throw ConnectionSignInError.browserUnavailable(browser.name) }
    }
}

enum ConnectionSignInError: LocalizedError {
    case cancelled, expired, browserUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Connection cancelled. Your local vaults are ready to use."
        case .expired: "The sign-in request expired. Choose Connect to Console to start again."
        case .browserUnavailable(let name): "Planisphere could not open \(name ?? "a browser"). Choose another browser and try again."
        }
    }
}
