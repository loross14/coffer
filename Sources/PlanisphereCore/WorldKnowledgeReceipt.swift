import Foundation

/// Local routing index. Original identity is a pointer, never a declaration of authority.
public struct WorldKnowledgeReceipt: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public let vaultID: UUID
        public let root: String
        public let path: String
        public let sha256: String
        public let originalID: String
        public let title: String
        public let aliases: [String]
        public let topics: [String]
        public let modifiedAt: String
        public let observedAt: String
        public let authority: String
        public let freshness: String
        init(vaultID: UUID, root: String, path: String, sha256: String, text: String, modifiedAt: Date) {
            self.vaultID = vaultID; self.root = root; self.path = path; self.sha256 = sha256
            originalID = VaultFS.hash(Data((vaultID.uuidString + "\u{0}" + path).utf8))
            let lines = text.components(separatedBy: .newlines)
            title = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            aliases = Self.metadata(lines, keys: ["aliases", "alias"])
            let headings = lines.filter { $0.hasPrefix("## ") }.prefix(12).map { String($0.dropFirst(3)) }
            let explicit = Self.metadata(lines, keys: ["topics", "tags", "keywords"])
            // Titles, aliases, and section headings remain whole phrases for downstream keyword matching.
            topics = Array(Set([title] + aliases + explicit + headings)).sorted()
            self.modifiedAt = ISO8601DateFormatter().string(from: modifiedAt)
            observedAt = ISO8601DateFormatter().string(from: Date())
            authority = "unassessed; original source identity is not authority"
            freshness = "snapshot; verify the current original and fingerprint before consequential use"
        }
        /// A deliberately limited frontmatter reader: scalar, inline list, and simple block-list values.
        /// Complex YAML is left uninterpreted rather than being presented as resolved metadata.
        private static func metadata(_ lines: [String], keys: Set<String>) -> [String] {
            guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
            var values: [String] = [], collecting = false
            func clean(_ value: String) -> String {
                value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            for line in lines[1..<end] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if collecting && trimmed.hasPrefix("- ") { values.append(clean(String(trimmed.dropFirst(2)))); continue }
                collecting = false
                guard let colon = trimmed.firstIndex(of: ":"), keys.contains(String(trimmed[..<colon]).lowercased()) else { continue }
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.isEmpty { collecting = true }
                else if value.hasPrefix("["), value.hasSuffix("]") { values += value.dropFirst().dropLast().split(separator: ",").map { clean(String($0)) } }
                else if !value.contains(where: { "{}&*!|>".contains($0) }) { values.append(clean(value)) }
            }
            return Array(Set(values.filter { !$0.isEmpty && $0.count <= 200 })).sorted()
        }
    }
    public struct Coverage: Codable, Sendable {
        public let vaultID: UUID
        public let root: String
        public let indexedNotes: Int
        public let oversizedNotes: Int
        public let excludedEntries: Int
        public let excludedPaths: [String]
        public let scopeSHA256: String?
        public let limitations: String
    }
    public let schema: String
    public let operationID: UUID
    public let sources: [UUID]
    public let createdAt: Date
    public let evidence: [Source]
    public let coverage: [Coverage]
    public let files: [String: String]
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
