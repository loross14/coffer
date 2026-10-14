import CryptoKit
import Foundation
import XCTest
@testable import PlanisphereModel

final class BuiltInModelTests: XCTestCase {
    private var root: URL!
    private let bytes = Data("gguf fixture bytes".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func spec(sha: String? = nil, size: Int64? = nil) -> ModelSpec {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ModelSpec(identifier: "planisphere-support", name: "Fixture", modelKey: "fixture-q4", fileName: "fixture.gguf",
                         source: URL(string: "https://example.invalid/fixture.gguf")!, sha256: sha ?? digest,
                         sizeBytes: size ?? Int64(bytes.count), contextLength: 8192, port: 41234)
    }

    private func source() throws -> URL {
        let url = root.appendingPathComponent("download.gguf")
        try bytes.write(to: url)
        return url
    }

    func testCopyInstallVerifiesAndWritesAPrivateRecordTheHostAccepts() throws {
        let location = ModelLocation(directory: root.appendingPathComponent("Models"))
        let original = try source()
        let record = try ModelStore.install(from: original, move: false, spec: spec(), at: location)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "a copied source stays in place")
        XCTAssertEqual(try Data(contentsOf: location.modelFile(spec())), bytes)
        XCTAssertEqual(record.endpoint, "http://127.0.0.1:41234")
        XCTAssertEqual(ModelStore.installed(spec: spec(), at: location), record)
        let mode = try FileManager.default.attributesOfItem(atPath: location.runtimeRecord.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the host refuses a runtime record others can read")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: location.runtimeRecord)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertEqual(json?["contextLength"] as? Int, 8192)
    }

    func testMovedDownloadIsConsumedAndReinstallReplacesTheRecord() throws {
        let location = ModelLocation(directory: root.appendingPathComponent("Models"))
        let first = try source()
        try ModelStore.install(from: first, move: true, spec: spec(), at: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        try ModelStore.install(from: try source(), move: true, spec: spec(), at: location)
        XCTAssertNotNil(ModelStore.installed(spec: spec(), at: location))
    }

    func testMismatchedFingerprintOrSizeIsNeverPublished() throws {
        let location = ModelLocation(directory: root.appendingPathComponent("Models"))
        XCTAssertThrowsError(try ModelStore.install(from: try source(), move: false, spec: spec(sha: String(repeating: "0", count: 64)), at: location)) {
            XCTAssertEqual($0 as? ModelError, .checksumMismatch)
        }
        XCTAssertThrowsError(try ModelStore.install(from: try source(), move: false, spec: spec(size: 5), at: location)) {
            XCTAssertEqual($0 as? ModelError, .wrongSize)
        }
        XCTAssertNil(ModelStore.installed(spec: spec(), at: location))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: location.directory.path)
        XCTAssertEqual(leftovers, [], "staged partial files are removed")
    }

    func testTruncatedFileOrDifferentPinIsNotTreatedAsInstalled() throws {
        let location = ModelLocation(directory: root.appendingPathComponent("Models"))
        try ModelStore.install(from: try source(), move: false, spec: spec(), at: location)
        XCTAssertNil(ModelStore.installed(spec: spec(sha: String(repeating: "a", count: 64)), at: location))
        try Data("short".utf8).write(to: location.modelFile(spec()))
        XCTAssertNil(ModelStore.installed(spec: spec(), at: location))
        try ModelStore.remove(spec: spec(), at: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.runtimeRecord.path))
    }

    func testServerServesOnlyOnLoopbackUnderTheRecordedAlias() throws {
        let location = ModelLocation(directory: root.appendingPathComponent("Models"))
        let record = try ModelStore.install(from: try source(), move: false, spec: spec(), at: location)
        let args = ModelStore.serverArguments(record, spec: spec())
        XCTAssertEqual(args[args.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertEqual(args[args.firstIndex(of: "--port")! + 1], "41234")
        XCTAssertEqual(args[args.firstIndex(of: "--alias")! + 1], "planisphere-support")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], ModelStore.canonical(location.modelFile(spec())))
        XCTAssertTrue(args.contains("--offline") && args.contains("--no-webui"))
    }

    func testExistingCopiesMustHaveThePinnedSize() throws {
        let home = root.appendingPathComponent("home")
        let folder = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("fixture.gguf"))
        XCTAssertEqual(ModelStore.existingCopies(spec: spec(), home: home).map(\.lastPathComponent), ["fixture.gguf"])
        XCTAssertEqual(ModelStore.existingCopies(spec: spec(size: 1), home: home), [])
    }
}
