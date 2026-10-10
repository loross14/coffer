import Foundation

public struct PruningScan: Decodable, Sendable {
    public let engineVersion: String
    public let scannedAt: String
    public let vaultPath: String
    public let notes: Int
    public let totalGroups: Int
    public let groups: [PruningGroup]
    public let diagnostics: [String]
    public let authority: PruningAuthority
    public let fingerprint: String
    public let scope: PruningScanScope
}

/// Coverage of candidate discovery, separate from the full write inventory.
public struct PruningScanScope: Decodable, Sendable {
    public let kind: String
    public let excludedPaths: [String]
    public let excludedCount: Int
    public let truncated: Bool
    public let appliedFilters: [String]
    public let unsupportedFilters: [String]
    public let limitations: [String]
}

public struct PruningGroup: Decodable, Sendable, Identifiable {
    public let id: String
    public let candidateKey: String
    public let members: [String]
    public let declaredCopies: Int
}

public struct PruningAuthority: Decodable, Sendable {
    public let status: String
    public let message: String?
    public let questions: [PruningQuestion]
}

public struct PruningQuestion: Decodable, Sendable, Identifiable {
    public var id: String { "\(scope.utf8.count):\(scope)\(question.utf8.count):\(question)" }
    public let scope: String
    public let question: String
    public let values: [String]
    public let state: String
    public let value: String?
    public let proofs: [String]
    public let writeState: String?
    public let hold: String?
}

public struct PruningChange: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let before: String?
    public let after: String?
    public var isRetired: Bool { after == nil }
}

public struct PruningPacket: Sendable {
    public let rawData: Data
    public let digest: String
    public let vaultPath: String
    public let scope: String
    public let question: String
    public let value: String
    public let validUntil: String
    public let changes: [PruningChange]

    // Only a successful engine preparation creates a packet in the native API.
    internal init(data: Data) throws {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let schema: String
                let vault: String
                let scope: String
                let question: String
                let value: String
                let valid_until: String
                let changes: [String: String?]
                let originals: [String: String]
            }
            let digest: String
            let packet: Payload
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.packet.schema == "grapheine-authority-v1",
              envelope.digest.count == 64,
              envelope.digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              !envelope.packet.changes.isEmpty,
              Set(envelope.packet.changes.keys) == Set(envelope.packet.originals.keys) else {
            throw GrapheineError.invalidResponse("The pruning packet is incomplete or uses an unsupported format.")
        }
        var previews: [PruningChange] = []
        for path in envelope.packet.changes.keys.sorted() {
            try GrapheineService.validateRelativePath(path)
            guard let encoded = envelope.packet.originals[path], let bytes = Data(base64Encoded: encoded),
                  let text = String(data: bytes, encoding: .utf8) else {
                throw GrapheineError.invalidResponse("A proposed file change has no readable original: \(path)")
            }
            previews.append(PruningChange(path: path, before: text, after: envelope.packet.changes[path] ?? nil))
        }
        rawData = data
        digest = envelope.digest
        vaultPath = envelope.packet.vault
        scope = envelope.packet.scope
        question = envelope.packet.question
        value = envelope.packet.value
        validUntil = envelope.packet.valid_until
        changes = previews
    }
}

public struct PruningApplyResult: Decodable, Sendable {
    public let commit: String
    public let message: String?
}

/// A local, unsigned proposal. The app asks the user to choose a keeper and
/// approve its exact changes; this type is never a signed authority receipt.
public struct LocalPruningPacket: Sendable {
    public struct Scope: Decodable, Sendable {
        public let version: Int
        public let excludedPaths: [String]
        public let sourceConfigurationSHA256: String?
    }

    public let rawData: Data
    public let digest: String
    public let vaultPath: String
    public let keepPath: String
    public let members: [String]
    public let files: [String: String]
    public let scope: Scope
    public let changes: [PruningChange]
    public let originals: [String: Data]
    public let limitations: [String]

    internal init(data: Data) throws {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let schema: String
                let vault: String
                let value: String
                let members: [String]
                let files: [String: String]
                let scope: Scope
                let changes: [String: String?]
                let originals: [String: String]
                let limitations: [String]
            }
            let digest: String
            let packet: Payload
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let packet = envelope.packet
        func validDigest(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        guard packet.schema == "planisphere-local-prune-v1", validDigest(envelope.digest),
              packet.scope.version == 2, packet.members.count >= 2, packet.members.count <= 1_000,
              Set(packet.members).count == packet.members.count, packet.members.contains(packet.value),
              packet.files.count <= 250_000, !packet.changes.isEmpty, packet.changes.count <= 10_000,
              packet.scope.excludedPaths.count <= 4_096, packet.limitations.count <= 100,
              Set(packet.changes.keys) == Set(packet.originals.keys),
              Set(packet.members).isSubset(of: Set(packet.files.keys)),
              Set(packet.changes.keys).isSubset(of: Set(packet.files.keys)),
              packet.files.values.allSatisfy(validDigest),
              packet.scope.sourceConfigurationSHA256.map(validDigest) ?? true else {
            throw GrapheineError.invalidResponse("The local pruning proposal is incomplete or uses an unsupported format.")
        }
        for path in packet.files.keys {
            try GrapheineService.validateRelativePath(path)
            guard path.hasSuffix(".md") else { throw GrapheineError.invalidResponse("The local proposal contains a non-Markdown file.") }
        }
        // The keeper remains present. Every other reviewed member must be an
        // explicit retirement; unrelated files may be rewritten, never retired.
        let retirements = Set(packet.changes.compactMap { key, value in value == nil ? key : nil })
        guard retirements == Set(packet.members).subtracting([packet.value]) else {
            throw GrapheineError.invalidResponse("The proposed retirements do not match the chosen note and reviewed group.")
        }
        var preview: [PruningChange] = []
        var originalBytes: [String: Data] = [:]
        for path in packet.changes.keys.sorted() {
            guard let encoded = packet.originals[path], let bytes = Data(base64Encoded: encoded),
                  let before = String(data: bytes, encoding: .utf8) else {
                throw GrapheineError.invalidResponse("A local change has no readable original: \(path)")
            }
            originalBytes[path] = bytes
            preview.append(PruningChange(path: path, before: before, after: packet.changes[path] ?? nil))
        }
        rawData = data; digest = envelope.digest; vaultPath = packet.vault
        keepPath = packet.value; members = packet.members; files = packet.files
        scope = packet.scope; changes = preview; originals = originalBytes; limitations = packet.limitations
    }
}

public enum GrapheineError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case refused(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .refused(let message), .invalidResponse(let message): message
        }
    }
}
