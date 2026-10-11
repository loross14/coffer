import SwiftUI
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        // Development binaries have no configured update channel. Distribution
        // packaging requires an HTTPS feed and a public update-signing key.
        if Bundle.main.bundleURL.pathExtension == "app",
           let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           URL(string: feed)?.scheme == "https",
           let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           Data(base64Encoded: publicKey)?.count == 32 {
            controller.startUpdater()
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
