import Foundation
import XCTest
@testable import PlanisphereModel

/// Opt-in (PLANISPHERE_MODEL_DOWNLOAD_TEST=1): the app's download code fetches the pinned 2.5 GB model
/// from Hugging Face into a temporary folder, then the normal install verifies size and fingerprint.
final class LiveDownloadTests: XCTestCase {
    func testPinnedModelDownloadsVerifiesAndInstalls() async throws {
        guard ProcessInfo.processInfo.environment["PLANISPHERE_MODEL_DOWNLOAD_TEST"] == "1" else {
            throw XCTSkip("Set PLANISPHERE_MODEL_DOWNLOAD_TEST=1 to download the pinned model")
        }
        let root = URL(fileURLWithPath: ModelStore.canonical(URL(fileURLWithPath: NSTemporaryDirectory())))
            .appendingPathComponent("model-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ModelLocation(directory: root.appendingPathComponent("Models"))
        let reports = Reports()
        let started = Date()
        let file = try await ModelDownload.fetch(ModelSpec.builtIn.source, into: location) { reports.add($0) }
        XCTAssertEqual(file.deletingLastPathComponent().path, location.directory.path, "downloads land in the model folder")
        let record = try ModelStore.install(from: file, move: true, at: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the verified download is moved, not copied")
        XCTAssertEqual(ModelStore.installed(at: location), record)
        XCTAssertGreaterThan(reports.count, 10, "progress is reported during the download")
        XCTAssertGreaterThanOrEqual(reports.last, 0.99)
        print("downloaded and verified in \(Int(Date().timeIntervalSince(started))) s")
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var last: Double { lock.lock(); defer { lock.unlock() }; return values.last ?? 0 }
}
