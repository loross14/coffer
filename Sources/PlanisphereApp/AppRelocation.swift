import AppKit
import Foundation

/// Offers, on launch, to move Planisphere into an Applications folder when it is running from
/// somewhere else (a Downloads folder, or the read-only translocated copy macOS makes of a
/// downloaded app). Everything registered from the bundle's path (the Local model's login item,
/// the Memory hooks) is re-registered on the first launch from the new home.
///
/// The decision logic is pure and tested; the moving, relaunching and alert live in
/// `AppRelocationModel`. No third-party code.
enum AppRelocation {
    /// Why the app is not in an Applications folder, or nil when it already is.
    enum Away: Equatable {
        /// macOS is running a temporary read-only copy; `original` is the downloaded app's location.
        case translocated(original: URL?)
        /// The app runs from an ordinary folder outside /Applications and ~/Applications.
        case elsewhere
    }

    static let declinedVersionKey = "relocation.declinedVersion"
    static let pendingReregistrationKey = "relocation.reregisterOnLaunch"

    static func isTranslocated(_ bundle: URL) -> Bool {
        bundle.path.contains("/AppTranslocation/")
    }

    /// True inside /Applications or the user's own Applications folder, at any depth.
    static func isInstalled(_ bundle: URL, home: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        let folders = ["/Applications", home.standardizedFileURL.path + "/Applications"]
        return folders.contains { path.hasPrefix($0 + "/") }
    }

    static func away(_ bundle: URL, home: URL, original: (URL) -> URL? = originalURL) -> Away? {
        if isTranslocated(bundle) {
            let source = original(bundle)
            if let source, isInstalled(source, home: home) { return nil }
            return .translocated(original: source)
        }
        return isInstalled(bundle, home: home) ? nil : .elsewhere
    }

    /// Offer once per build: a build the person declined is not asked about again,
    /// the next update asks once more.
    static func shouldOffer(bundle: URL, home: URL, version: String, declinedVersion: String?,
                            original: (URL) -> URL? = originalURL) -> Bool {
        guard bundle.pathExtension == "app", declinedVersion != version else { return false }
        return away(bundle, home: home, original: original) != nil
    }

    /// The folder whose name the alert shows: where the downloaded app actually sits.
    static func sourceFolderName(bundle: URL, away: Away) -> String {
        switch away {
        case .translocated(let original?): original.deletingLastPathComponent().lastPathComponent
        case .translocated(nil): "a temporary folder"
        case .elsewhere: bundle.deletingLastPathComponent().lastPathComponent
        }
    }

    /// /Applications when this account can write there, else ~/Applications (created on demand).
    static func destination(for bundle: URL, home: URL, fileManager: FileManager = .default) -> URL {
        let name = bundle.lastPathComponent
        if fileManager.isWritableFile(atPath: "/Applications") {
            return URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(name)
        }
        let personal = home.appendingPathComponent("Applications", isDirectory: true)
        try? fileManager.createDirectory(at: personal, withIntermediateDirectories: true)
        return personal.appendingPathComponent(name)
    }

    /// Moves the bundle. An app already at the destination goes to the Trash first (reversible).
    /// The quarantine mark is removed from the moved copy so macOS stops translocating it; the
    /// download is notarized, and Gatekeeper already assessed it on first open.
    static func move(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            // Another volume: copy, then remove the original only after the copy exists.
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: source)
        }
        removeQuarantine(destination, fileManager: fileManager)
    }

    static func removeQuarantine(_ root: URL, fileManager: FileManager = .default) {
        let name = "com.apple.quarantine"
        removexattr(root.path, name, XATTR_NOFOLLOW)
        guard let items = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return }
        for case let item as URL in items { removexattr(item.path, name, XATTR_NOFOLLOW) }
    }

    /// The shell command that waits for this process to exit, then opens the moved app.
    static func relaunchScript(pid: Int32, destination: URL) -> String {
        let quoted = "'" + destination.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \(quoted)"
    }

    /// Where a translocated app was launched from, via Security.framework's translocation API.
    /// Returns nil when the URL is not translocated or the API is unavailable.
    static func originalURL(_ bundle: URL) -> URL? {
        guard isTranslocated(bundle) else { return nil }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(symbol, to: Fn.self)
        return function(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }
}

/// Runs the offer at launch and the re-registration on the first launch after a move.
@MainActor
final class AppRelocationModel {
    struct Copy {
        let title: String
        let message: String
        let move = "Move to Applications"
        let later = "Not now"
    }

    private let defaults: UserDefaults
    private let bundle: URL
    private let home: URL
    private let version: String

    init(defaults: UserDefaults = .standard, bundle: URL = Bundle.main.bundleURL,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") {
        self.defaults = defaults; self.bundle = bundle; self.home = home; self.version = version
    }

    static func copy(folder: String) -> Copy {
        Copy(title: "Move Planisphere to your Applications folder?",
             message: "Planisphere is running from \(folder). Moving it to Applications gives it one stable home, so updates, the Local model and your agents' Memory connection keep working. Planisphere moves itself and reopens.")
    }

    /// Call from `applicationDidFinishLaunching`. Shows the alert when the app is away from
    /// Applications and this build has not been declined before.
    func offerIfNeeded() {
        guard AppRelocation.shouldOffer(bundle: bundle, home: home, version: version,
                                        declinedVersion: defaults.string(forKey: AppRelocation.declinedVersionKey)),
              let away = AppRelocation.away(bundle, home: home) else { return }
        let copy = Self.copy(folder: AppRelocation.sourceFolderName(bundle: bundle, away: away))
        let alert = Self.alert(copy)
        guard alert.runModal() == .alertFirstButtonReturn else {
            defaults.set(version, forKey: AppRelocation.declinedVersionKey)
            return
        }
        let source: URL
        switch away {
        case .translocated(let original?): source = original
        case .translocated(nil):
            Self.failed("macOS is running a temporary copy of Planisphere and did not say where the download is. Drag Planisphere from your Downloads folder into Applications, then open it from there.")
            return
        case .elsewhere: source = bundle
        }
        let destination = AppRelocation.destination(for: source, home: home)
        do {
            try AppRelocation.move(from: source, to: destination)
        } catch {
            Self.failed("Planisphere could not move itself. \(error.localizedDescription) Drag it into Applications by hand, then open it from there.")
            return
        }
        defaults.set(true, forKey: AppRelocation.pendingReregistrationKey)
        defaults.removeObject(forKey: AppRelocation.declinedVersionKey)
        defaults.synchronize()
        Self.relaunch(at: destination)
    }

    /// True once, on the first launch after `offerIfNeeded` moved the app.
    func consumePendingReregistration() -> Bool {
        guard defaults.bool(forKey: AppRelocation.pendingReregistrationKey) else { return false }
        defaults.removeObject(forKey: AppRelocation.pendingReregistrationKey)
        return true
    }

    static func alert(_ copy: Copy) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: copy.move)
        alert.addButton(withTitle: copy.later)
        return alert
    }

    private static func failed(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Planisphere stayed where it is"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func relaunch(at destination: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AppRelocation.relaunchScript(pid: ProcessInfo.processInfo.processIdentifier, destination: destination)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        NSApp.terminate(nil)
    }
}
