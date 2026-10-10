import Foundation
import XCTest
@testable import PlanisphereGrapheine

/// Transport-only coverage. The fixture helper neither verifies signatures nor
/// invokes Grapheine; a valid response here is not evidence of a real settlement.
final class ApplyTransportTests: XCTestCase, @unchecked Sendable {
    func testApplyPassesExactPacketThroughCanonicalPrivateTemporaryPath() async throws {
        let fixture = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("planisphere-apply-transport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let vault = fixture.appendingPathComponent("vault", isDirectory: true)
        let engine = fixture.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: false)
        // The service checks engine availability before starting its subprocess.
        try Data("# Transport fixture only.\n".utf8)
            .write(to: engine.appendingPathComponent("grapheine_authority.py"))
        let policy = fixture.appendingPathComponent("policy.json")
        let receipt = fixture.appendingPathComponent("receipt.json")
        try Data("{}".utf8).write(to: policy)
        try Data("{}".utf8).write(to: receipt)

        let rawPacket = try JSONSerialization.data(withJSONObject: [
            "digest": String(repeating: "a", count: 64),
            "packet": [
                "schema": "grapheine-authority-v1", "vault": vault.path,
                "scope": "transport-fixture", "question": "account",
                "value": "current.md", "valid_until": "2099-01-01T00:00:00+00:00",
                "changes": ["older.md": NSNull()],
                "originals": ["older.md": Data("# Original\r\nCafé\n".utf8).base64EncodedString()]
            ] as [String: Any]
        ], options: [.prettyPrinted, .sortedKeys])
        let packet = try PruningPacket(data: rawPacket)
        let helper = fixture.appendingPathComponent("transport-helper.py")
        let helperSource = """
        import base64
        import json
        import os
        from pathlib import Path
        import stat
        import sys

        try:
            assert sys.argv[1] == "apply", "unexpected action"
            packet = Path(sys.argv[sys.argv.index("--packet") + 1])
            assert packet.is_absolute(), "packet path is not absolute"
            assert str(packet) == os.path.realpath(packet), "packet path is not canonical"
            for path in [packet, *packet.parents]:
                assert not stat.S_ISLNK(path.lstat().st_mode), "symlink packet ancestor: " + str(path)
            assert stat.S_IMODE(packet.parent.stat().st_mode) == 0o700, "packet directory is not private"
            assert stat.S_IMODE(packet.stat().st_mode) == 0o600, "packet file is not private"
            assert packet.read_bytes() == base64.b64decode("\(rawPacket.base64EncodedString())"), "packet bytes changed"
            print(json.dumps({"commit": "\(String(repeating: "b", count: 40))", "message": "transport fixture verified exact packet"}))
        except Exception as error:
            print(json.dumps({"error": str(error)}))
            raise SystemExit(2)
        """
        try Data(helperSource.utf8).write(to: helper)

        let service = GrapheineService(helperURL: helper, engineURL: engine,
                                       pythonURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let result = try await service.apply(vaultURL: vault, policyURL: policy,
                                             packet: packet, receiptURL: receipt)
        XCTAssertEqual(result.commit, String(repeating: "b", count: 40))
        XCTAssertEqual(result.message, "transport fixture verified exact packet")
    }
}
