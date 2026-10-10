import Foundation
import XCTest
@testable import PlanisphereGrapheine

final class LocalPruningTests: XCTestCase, @unchecked Sendable {
    func testRealLocalProposalAndFreshnessWorkWithoutGitOrPolicy() async throws {
        let fixture = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("planisphere-local-proposal-" + UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let note = "# Account\n\nShared explanation.\n"
        try Data(note.utf8).write(to: fixture.appendingPathComponent("Status.md"))
        try Data(note.utf8).write(to: fixture.appendingPathComponent("Archive/Status.md"))
        try Data("See [[Archive/Status]].\n".utf8).write(to: fixture.appendingPathComponent("Reader.md"))
        let service = GrapheineService()
        let scan = try await service.scan(vaultURL: fixture)
        let group = try XCTUnwrap(scan.groups.first { Set($0.members) == Set(["Status.md", "Archive/Status.md"]) })
        let packet = try await service.prepareLocal(vaultURL: fixture, members: group.members, keepPath: "Status.md", fingerprint: scan.fingerprint)
        XCTAssertEqual(packet.keepPath, "Status.md")
        XCTAssertTrue(try XCTUnwrap(packet.changes.first { $0.path == "Archive/Status.md" }).isRetired)
        XCTAssertNotNil(packet.changes.first { $0.path == "Reader.md" }?.after)
        let verified = try await service.verifyLocal(vaultURL: fixture, packet: packet)
        XCTAssertEqual(verified.digest, packet.digest)
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("Archive/Status.md"), encoding: .utf8), note)
        XCTAssertFalse(manager.fileExists(atPath: fixture.appendingPathComponent(".git").path))

        try Data("New work after review.\n".utf8).write(to: fixture.appendingPathComponent("Reader.md"))
        do {
            _ = try await service.verifyLocal(vaultURL: fixture, packet: packet)
            XCTFail("A proposal from before a working edit must not verify")
        } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("changed") || error.localizedDescription.lowercased().contains("stale")) }
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("Archive/Status.md"), encoding: .utf8), note)
    }

    func testLocalPacketPreservesBytesAndExplicitKeeper() throws {
        let packet = try LocalPruningPacket(data: packetData())
        XCTAssertEqual(packet.keepPath, "current.md")
        XCTAssertEqual(packet.members, ["current.md", "older.md"])
        XCTAssertEqual(packet.originals["older.md"], Data("# Older\r\nCafé\n".utf8))
        XCTAssertEqual(packet.changes.first?.before, "# Older\r\nCafé\n")
        XCTAssertTrue(try XCTUnwrap(packet.changes.first).isRetired)
        XCTAssertEqual(packet.scope.version, 4)
        XCTAssertEqual(packet.scope.excludedPaths, ["Archive/"])
        XCTAssertNil(packet.scope.sourceConfigurationSHA256)
    }

    func testLocalPacketRefusesUnreviewedRetirementsAndMissingOriginals() throws {
        for alter in ["keeper", "outside", "missing", "scope", "path"] {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: packetData()) as? [String: Any])
            var packet = try XCTUnwrap(envelope["packet"] as? [String: Any])
            switch alter {
            case "keeper":
                packet["value"] = "older.md"
            case "outside":
                packet["changes"] = ["older.md": NSNull(), "reader.md": NSNull()]
                packet["originals"] = ["older.md": Data("# Older\r\nCafé\n".utf8).base64EncodedString(),
                    "reader.md": Data("[[older]]\n".utf8).base64EncodedString()]
            case "missing":
                packet["originals"] = [:] as [String: String]
            case "scope":
                packet["scope"] = ["version": 1, "excludedPaths": []] as [String: Any]
            default:
                var files = try XCTUnwrap(packet["files"] as? [String: String])
                files["../outside.md"] = String(repeating: "b", count: 64)
                packet["files"] = files
            }
            envelope["packet"] = packet
            XCTAssertThrowsError(try LocalPruningPacket(data: JSONSerialization.data(withJSONObject: envelope)), alter)
        }
    }

    /// The helper only checks transport. It is not evidence of preservation
    /// analysis, signed authority or a real local write.
    func testLocalServiceTransportsExplicitChoiceAndFingerprintThenVerifies() async throws {
        let fixture = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("planisphere-local-transport-" + UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let vault = fixture.appendingPathComponent("vault"), engine = fixture.appendingPathComponent("engine")
        try manager.createDirectory(at: vault, withIntermediateDirectories: false)
        try manager.createDirectory(at: engine, withIntermediateDirectories: false)
        try Data("# Transport-only engine fixture\n".utf8).write(to: engine.appendingPathComponent("grapheine_authority.py"))
        let data = try packetData(vaultPath: vault.path)
        let helper = fixture.appendingPathComponent("helper.py")
        let source = """
        import base64, json, os, stat, sys
        from pathlib import Path
        payload = base64.b64decode("\(data.base64EncodedString())")
        try:
            assert "--policy" not in sys.argv, "local transport must not receive policy"
            assert sys.argv[sys.argv.index("--vault") + 1] == "\(vault.path)", "wrong vault"
            if sys.argv[1] == "prepare-local":
                assert json.loads(sys.argv[sys.argv.index("--members") + 1]) == ["current.md", "older.md"], "wrong members"
                assert sys.argv[sys.argv.index("--keep") + 1] == "current.md", "wrong keeper"
                assert sys.argv[sys.argv.index("--fingerprint") + 1] == "\(String(repeating: "f", count: 64))", "wrong fingerprint"
            else:
                assert sys.argv[1] == "verify-local", "wrong operation"
                packet = Path(sys.argv[sys.argv.index("--packet") + 1])
                assert packet.read_bytes() == payload, "packet bytes changed"
                assert os.path.realpath(packet) == str(packet), "packet path not canonical"
                assert stat.S_IMODE(packet.stat().st_mode) == 0o600, "packet not private"
            sys.stdout.write(payload.decode())
        except Exception as error:
            print(json.dumps({"error": str(error)}))
            raise SystemExit(2)
        """
        try Data(source.utf8).write(to: helper)
        let service = GrapheineService(helperURL: helper, engineURL: engine, pythonURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let packet = try await service.prepareLocal(vaultURL: vault, members: ["current.md", "older.md"], keepPath: "current.md",
            fingerprint: String(repeating: "f", count: 64))
        let verified = try await service.verifyLocal(vaultURL: vault, packet: packet)
        XCTAssertEqual(verified.rawData, data)
        XCTAssertFalse(manager.fileExists(atPath: vault.appendingPathComponent(".git").path))

        var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try XCTUnwrap(altered["packet"] as? [String: Any])
        body["changes"] = ["older.md": NSNull(), "reader.md": "Altered without changing the claimed digest.\n"] as [String: Any]
        altered["packet"] = body
        let tampered = try JSONSerialization.data(withJSONObject: altered, options: [.sortedKeys])
        try Data("import base64, sys\nsys.stdout.write(base64.b64decode('\(tampered.base64EncodedString())').decode())\n".utf8).write(to: helper)
        do {
            _ = try await service.verifyLocal(vaultURL: vault, packet: packet)
            XCTFail("A verifier response with altered content under the original digest must be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no longer current")) }
    }

    private func packetData(vaultPath: String = "/private/tmp/local-fixture") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "digest": String(repeating: "a", count: 64),
            "packet": [
                "schema": "planisphere-local-prune-v1", "vault": vaultPath,
                "value": "current.md", "members": ["current.md", "older.md"],
                "files": ["current.md": String(repeating: "b", count: 64), "older.md": String(repeating: "c", count: 64),
                          "reader.md": String(repeating: "d", count: 64)],
                "scope": ["version": 4, "excludedPaths": ["Archive/"], "sourceConfigurationSHA256": NSNull()] as [String: Any],
                "changes": ["older.md": NSNull(), "reader.md": "[[current|older]]\n"] as [String: Any],
                "originals": ["older.md": Data("# Older\r\nCafé\n".utf8).base64EncodedString(),
                              "reader.md": Data("[[older]]\n".utf8).base64EncodedString()],
                "limitations": ["Markdown scope only; excluded notes may contain links."]
            ] as [String: Any]
        ], options: [.sortedKeys])
    }
}
