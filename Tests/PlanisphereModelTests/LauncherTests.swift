import Foundation
import XCTest
@testable import PlanisphereModel

/// Runs the built launcher the way launchd runs a BundleProgram: relative argv[0], working directory "/".
final class LauncherTests: XCTestCase {
    func testLauncherFindsTheServerBesideItselfWhenStartedWithARelativeName() throws {
        let built = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("planisphere-model")
        guard FileManager.default.isExecutableFile(atPath: built.path) else { throw XCTSkip("planisphere-model was not built") }
        let root = URL(fileURLWithPath: ModelStore.canonical(URL(fileURLWithPath: NSTemporaryDirectory())))
            .appendingPathComponent("launcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helpers = root.appendingPathComponent("App/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: helpers.appendingPathComponent("planisphere-model"))
        let received = root.appendingPathComponent("server-arguments.txt")
        let server = helpers.appendingPathComponent("planisphere-model-server")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(received.path)'\n".write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        // A sparse file of the pinned size stands in for the model; the launcher checks size, not content.
        let spec = ModelSpec.builtIn
        let location = ModelLocation.standard(dataDirectory: root.appendingPathComponent("Data"))
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let model = location.modelFile(spec)
        FileManager.default.createFile(atPath: model.path, contents: nil)
        try FileHandle(forWritingTo: model).truncate(atOffset: UInt64(spec.sizeBytes))
        try ModelStore.write(RuntimeRecord(identifier: spec.identifier, name: spec.name, model: spec.modelKey, endpoint: spec.endpoint,
                                           path: ModelStore.canonical(model), sha256: spec.sha256, sizeBytes: spec.sizeBytes,
                                           contextLength: spec.contextLength), to: location.runtimeRecord)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "cd / && exec -a Contents/Helpers/planisphere-model \"$0\"", helpers.appendingPathComponent("planisphere-model").path]
        process.environment = ["PLANISPHERE_DATA_DIR": root.appendingPathComponent("Data").path, "PATH": "/usr/bin:/bin"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let arguments = try String(contentsOf: received, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], ModelStore.canonical(model))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--port")! + 1], "41234")
    }
}
