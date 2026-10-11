import Foundation

/// Source text is replaced as data; this API never executes it.
public typealias TextMutation = MarkdownMutation
public typealias TextMutationReceipt = MarkdownMutationReceipt

internal struct TextMutationReview: Codable, Equatable, Sendable {
    let extensions: [String]
    let entries: [FileEntry]

    func validate(scope: CheckpointScope, expectedFiles: [String: String]) throws {
        guard scope.version == 3, !extensions.isEmpty,
              extensions == Array(Set(extensions)).sorted(),
              extensions.allSatisfy(TextMutationPlan.supportedExtensions.contains),
              entries.count <= 250_000, entries.map(\.path) == entries.map(\.path).sorted() else {
            throw VaultStoreError.invalid("The reviewed text inventory or format selection is invalid.")
        }
        var seen = Set<String>(), kinds: [String: FileEntry.Kind] = [:], files: [String: String] = [:]
        var total: Int64 = 0
        for entry in entries {
            try VaultFS.relative(entry.path)
            guard seen.insert(VaultFS.portablePathKey(entry.path)).inserted,
                  !scope.excludes(entry.path, isDirectory: entry.kind == .directory,
                                  isSymbolicLink: entry.kind == .symbolicLink, isRegularFile: entry.kind == .file),
                  entry.size >= 0 else { throw VaultStoreError.invalid("Invalid reviewed text inventory entry.") }
            let parts = entry.path.split(separator: "/")
            for index in 1..<parts.count {
                let parent = parts.prefix(index).joined(separator: "/")
                guard kinds[parent] == .directory, !scope.excludes(parent, isDirectory: true) else {
                    throw VaultStoreError.invalid("The reviewed text inventory has an excluded or non-directory parent.")
                }
            }
            kinds[entry.path] = entry.kind
            if entry.kind == .directory {
                guard entry.digest == nil, entry.size == 0, !entry.executable else {
                    throw VaultStoreError.invalid("Invalid reviewed directory entry.")
                }
            } else {
                guard let digest = entry.digest, digest.count == 64,
                      digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw VaultStoreError.invalid("Invalid reviewed content digest.")
                }
                if entry.kind == .symbolicLink {
                    guard !entry.executable, entry.size > 0, entry.size <= Int64(VaultFS.symbolicLinkLimit) else {
                        throw VaultStoreError.invalid("Invalid reviewed symbolic link.")
                    }
                } else { files[entry.path] = digest }
                let (sum, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow else { throw VaultStoreError.invalid("Reviewed inventory size overflow.") }
                total = sum
            }
        }
        guard files == expectedFiles else { throw VaultStoreError.invalid("Reviewed file hashes disagree with the complete inventory.") }
    }
}

/// An opt-in text repair, separate from Markdown pruning. It pins every entry
/// of a reviewed Vault Content checkpoint, including attachments and link targets.
/// Only existing UTF-8, NUL-free source files in the selected formats may change.
public struct TextMutationPlan: Codable, Equatable, Sendable {
    public static let supportedExtensions: Set<String> = ["md", "tex", "bib", "sty", "cls", "py", "sh", "txt", "json", "html", "css", "js", "ts", "yaml", "yml"]
    internal let plan: MarkdownMutationPlan
    public var id: UUID { plan.id }
    public var digest: String { plan.digest }
    public var vaultID: UUID { plan.vaultID }
    public var vaultPath: String { plan.vaultPath }
    public var scope: CheckpointScope { plan.scope }
    public var changes: [TextMutation] { plan.changes }
    public var expectedEntries: [FileEntry] { plan.textReview?.entries ?? [] }

    public init(id: UUID = UUID(), vaultID: UUID, vaultPath: String, scope: CheckpointScope,
                expectedEntries: [FileEntry], extensions: [String], changes: [TextMutation], reviewedPacket: Data) throws {
        var files: [String: String] = [:]
        for entry in expectedEntries where entry.kind == .file {
            guard files[entry.path] == nil, let digest = entry.digest else {
                throw VaultStoreError.invalid("The text review includes a duplicate or unhashed file.")
            }
            files[entry.path] = digest
        }
        plan = try MarkdownMutationPlan(id: id, vaultID: vaultID, vaultPath: vaultPath, scope: scope,
                                        expectedFiles: files, changes: changes, reviewedPacket: reviewedPacket,
                                        textReview: TextMutationReview(extensions: extensions, entries: expectedEntries))
    }
}
