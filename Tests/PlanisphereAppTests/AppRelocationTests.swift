import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import PlanisphereApp

final class AppRelocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/pax", isDirectory: true)
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private let translocated = URL(fileURLWithPath: "/private/var/folders/x1/T/AppTranslocation/9F3C-1D2E/d/Planisphere.app")

    func testOnlyAppsOutsideApplicationsAreAway() {
        XCTAssertNil(AppRelocation.away(url("/Applications/Planisphere.app"), home: home))
        XCTAssertNil(AppRelocation.away(url("/Users/pax/Applications/Planisphere.app"), home: home))
        XCTAssertNil(AppRelocation.away(url("/Applications/Utilities/Planisphere.app"), home: home))
        XCTAssertEqual(AppRelocation.away(url("/Users/pax/Downloads/Planisphere.app"), home: home), .elsewhere)
        XCTAssertEqual(AppRelocation.away(url("/Users/pax/Desktop/Planisphere.app"), home: home), .elsewhere)
        XCTAssertEqual(AppRelocation.away(url("/Applications Extra/Planisphere.app"), home: home), .elsewhere, "prefix match is on the folder, not the string")
    }

    func testTranslocatedCopyResolvesToTheDownload() {
        let download = url("/Users/pax/Downloads/Planisphere.app")
        XCTAssertTrue(AppRelocation.isTranslocated(translocated))
        XCTAssertEqual(AppRelocation.away(translocated, home: home, original: { _ in download }), .translocated(original: download))
        XCTAssertEqual(AppRelocation.away(translocated, home: home, original: { _ in nil }), .translocated(original: nil))
        XCTAssertNil(AppRelocation.away(translocated, home: home, original: { _ in self.url("/Applications/Planisphere.app") }),
                     "a translocated copy of an installed app is not asked to move")
        XCTAssertEqual(AppRelocation.sourceFolderName(bundle: translocated, away: .translocated(original: download)), "Downloads")
        XCTAssertEqual(AppRelocation.sourceFolderName(bundle: translocated, away: .translocated(original: nil)), "a temporary folder")
        XCTAssertEqual(AppRelocation.sourceFolderName(bundle: url("/Users/pax/Desktop/Planisphere.app"), away: .elsewhere), "Desktop")
    }

    func testOfferOncePerBuildAndNeverForUnpackagedBuilds() {
        let download = url("/Users/pax/Downloads/Planisphere.app")
        XCTAssertTrue(AppRelocation.shouldOffer(bundle: download, home: home, version: "25", declinedVersion: nil))
        XCTAssertFalse(AppRelocation.shouldOffer(bundle: download, home: home, version: "25", declinedVersion: "25"), "Not now holds for this build")
        XCTAssertTrue(AppRelocation.shouldOffer(bundle: download, home: home, version: "26", declinedVersion: "25"), "the next update asks once more")
        XCTAssertFalse(AppRelocation.shouldOffer(bundle: url("/Applications/Planisphere.app"), home: home, version: "25", declinedVersion: nil))
        XCTAssertFalse(AppRelocation.shouldOffer(bundle: url("/Users/pax/code/.build/debug/Planisphere"), home: home, version: "25", declinedVersion: nil),
                       "swift run and test hosts are not asked")
    }

    func testOriginalPathAPIIsAvailableAndIgnoresOrdinaryPaths() {
        XCTAssertNil(AppRelocation.originalURL(url("/Users/pax/Downloads/Planisphere.app")))
        let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        XCTAssertNotNil(handle.flatMap { dlsym($0, "SecTranslocateCreateOriginalPathForURL") }, "Security.framework exposes the translocation lookup on this macOS")
    }

    func testDestinationKeepsTheBundleNameInsideAnApplicationsFolder() {
        let destination = AppRelocation.destination(for: url("/Users/pax/Downloads/Planisphere.app"), home: home)
        XCTAssertEqual(destination.lastPathComponent, "Planisphere.app")
        XCTAssertTrue(["/Applications", "/Users/pax/Applications"].contains(destination.deletingLastPathComponent().path))
    }

    func testMoveCarriesTheBundleAndDropsQuarantine() throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("PlanisphereMove-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Downloads/Planisphere.app", isDirectory: true)
        let inner = source.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: inner.appendingPathComponent("Planisphere"))
        let mark = "0083;00000000;Chrome;"
        for path in [source.path, inner.appendingPathComponent("Planisphere").path] {
            XCTAssertEqual(setxattr(path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0), 0)
        }
        let applications = base.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let destination = applications.appendingPathComponent("Planisphere.app")

        try AppRelocation.move(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Contents/MacOS/Planisphere")), Data("bin".utf8))
        for path in [destination.path, destination.appendingPathComponent("Contents/MacOS/Planisphere").path] {
            XCTAssertEqual(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0), -1, "\(path) still quarantined")
        }
    }

    func testRelaunchScriptWaitsForThisProcessAndQuotesThePath() {
        let script = AppRelocation.relaunchScript(pid: 4242, destination: url("/Applications/Pax's Apps/Planisphere.app"))
        XCTAssertEqual(script, "while /bin/kill -0 4242 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open '/Applications/Pax'\\''s Apps/Planisphere.app'")
    }

    @MainActor
    func testPendingReregistrationIsConsumedOnce() throws {
        let suite = "ooo.planisphere.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppRelocationModel(defaults: defaults, bundle: url("/Applications/Planisphere.app"), home: home, version: "25")
        XCTAssertFalse(model.consumePendingReregistration())
        defaults.set(true, forKey: AppRelocation.pendingReregistrationKey)
        XCTAssertTrue(model.consumePendingReregistration())
        XCTAssertFalse(model.consumePendingReregistration(), "one relaunch, one re-registration")
    }

    @MainActor
    final class FakeItem: BackgroundItem {
        var status: SMAppService.Status
        var calls: [String] = []
        init(status: SMAppService.Status) { self.status = status }
        func register() throws { calls.append("register"); status = .enabled }
        func unregister() async throws { calls.append("unregister"); status = .notRegistered }
    }

    @MainActor
    func testEnabledModelItemIsReregisteredFromTheNewPathAndOthersAreLeftAlone() async throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("PlanisphereRuntime-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let enabled = FakeItem(status: .enabled)
        let runtime = ModelRuntimeModel(location: .standard(dataDirectory: base), home: base, service: enabled)
        let reregistered = await runtime.reregisterAfterMove()
        XCTAssertTrue(reregistered)
        XCTAssertEqual(enabled.calls, ["unregister", "register"])

        for status in [SMAppService.Status.notRegistered, .notFound, .requiresApproval] {
            let item = FakeItem(status: status)
            let other = ModelRuntimeModel(location: .standard(dataDirectory: base), home: base, service: item)
            let touched = await other.reregisterAfterMove()
            XCTAssertFalse(touched)
            XCTAssertEqual(item.calls, [], "\(status) was never registered from the old path")
        }
    }

    @MainActor
    func testAlertCopyNamesTheFolderAndWhatStaysWorking() {
        let copy = AppRelocationModel.copy(folder: "Downloads")
        XCTAssertEqual(copy.title, "Move Planisphere to your Applications folder?")
        XCTAssertTrue(copy.message.hasPrefix("Planisphere is running from Downloads."))
        for word in ["Local model", "Memory", "updates", "reopens"] { XCTAssertTrue(copy.message.contains(word), word) }
        XCTAssertEqual(copy.move, "Move to Applications")
        XCTAssertEqual(copy.later, "Not now")
    }

    /// Opt-in: renders the launch alert's copy in an alert-shaped facsimile for design review.
    /// NSAlert builds its views only inside runModal, so the system alert itself cannot be
    /// captured headless; the words and buttons are the ones `offerIfNeeded` shows.
    /// PLANISPHERE_RENDER_OUT=<folder>
    @MainActor
    func testRenderMoveAlertForReview() throws {
        guard let out = ProcessInfo.processInfo.environment["PLANISPHERE_RENDER_OUT"] else { throw XCTSkip("set PLANISPHERE_RENDER_OUT") }
        let copy = AppRelocationModel.copy(folder: "Downloads")
        let facsimile = VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: .applicationBundle)).resizable().frame(width: 64, height: 64)
            Text(copy.title).font(.system(size: 13, weight: .bold)).multilineTextAlignment(.center)
            Text(copy.message).font(.system(size: 11)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Text(copy.move).font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
                Text(copy.later).font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 6))
            }.padding(.top, 6)
        }
        .padding(20).frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .padding(24).background(Color.black.opacity(0.85))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: facsimile)
        renderer.scale = 2
        var image: NSImage?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(try XCTUnwrap(image).tiffRepresentation)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out).appendingPathComponent("move-to-applications-alert-facsimile.png"))
        XCTAssertGreaterThan(png.count, 5_000)
    }
}
