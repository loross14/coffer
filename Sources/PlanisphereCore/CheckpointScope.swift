import Foundation
import Darwin

public enum CheckpointMode: String, CaseIterable, Sendable {
    case markdownOnly, vaultContent, wholeFolder
}

/// Frozen, inspectable rules for an explicitly reviewed checkpoint.
/// Nil scope on a checkpoint continues to mean the complete folder.
public struct CheckpointScope: Codable, Equatable, Sendable {
    public let version: Int
    public let excludedPaths: [String]
    public let sourceConfigurationSHA256: String?

    // Version 1 retains its original encoded shape and Vault Content behavior.
    // A computed mode does not alter the checksums of existing manifests.
    public var mode: CheckpointMode { [2, 4].contains(version) ? .markdownOnly : .vaultContent }

    public static func markdownOnly(excludedPaths: [String], sourceConfigurationSHA256: String?) throws -> CheckpointScope {
        let scope = CheckpointScope(excludedPaths: excludedPaths, sourceConfigurationSHA256: sourceConfigurationSHA256, mode: .markdownOnly)
        try scope.validate()
        return scope
    }

    internal init(excludedPaths: [String], sourceConfigurationSHA256: String?, mode: CheckpointMode = .vaultContent) {
        version = mode == .markdownOnly ? 4 : 3
        self.excludedPaths = excludedPaths
        self.sourceConfigurationSHA256 = sourceConfigurationSHA256
    }

    public func excludes(_ relativePath: String, isDirectory: Bool, isSymbolicLink: Bool = false, isRegularFile: Bool = true) -> Bool {
        exclusionReason(relativePath, isDirectory: isDirectory, isSymbolicLink: isSymbolicLink, isRegularFile: isRegularFile) != nil
    }

    internal func exclusionReason(_ path: String, isDirectory: Bool, isSymbolicLink: Bool = false, isRegularFile: Bool = true) -> String? {
        for rule in excludedPaths {
            let target = rule.hasSuffix("/") ? String(rule.dropLast()) : rule
            // Match the path itself without probing whether a link points to a folder.
            if path == target {
                return "Planisphere excluded path"
            }
            if path.hasPrefix(target + "/") { return "Planisphere excluded path" }
        }
        // Settings are part of the vault, including plugins' hidden state. Only
        // explicit user filters may omit entries inside this configuration tree.
        let settingsFolder = version <= 2 ? ".obsidian" : ".planisphere"
        if mode == .vaultContent && (path == settingsFolder || path.hasPrefix(settingsFolder + "/")) { return nil }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if isDirectory && name.hasPrefix(".") {
            return mode == .markdownOnly ? "Hidden folder" : "Hidden folder outside saved settings"
        }
        if isDirectory && ["node_modules", "__pycache__"].contains(name) {
            return "Generated dependency folder"
        }
        if mode == .markdownOnly && !isDirectory {
            if isSymbolicLink { return "Symbolic link; Markdown Only saves regular files" }
            if !isRegularFile { return "Special file; Markdown Only saves regular files" }
            if !name.hasSuffix(".md") { return "Not a lowercase .md file" }
        }
        return nil
    }

    internal func validate() throws {
        guard [1, 2, 3, 4].contains(version), excludedPaths.count <= 4096,
              excludedPaths == Array(Set(excludedPaths)).sorted(),
              excludedPaths.allSatisfy(Self.isLiteralPath) else {
            throw VaultStoreError.corrupt("invalid checkpoint content scope")
        }
        if let digest = sourceConfigurationSHA256 {
            guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw VaultStoreError.corrupt("invalid checkpoint scope configuration hash")
            }
        }
    }

    internal func verifySource(_ source: VaultFS.Handle) throws {
        guard version >= 3 else {
            throw VaultStoreError.invalid("This review used retired scope settings. Review again with Planisphere settings before saving.")
        }
        guard try Self.load(source, mode: mode).scope == self else {
            throw VaultStoreError.invalid("Planisphere exclusions changed after review. Review the checkpoint again before saving.")
        }
    }

    private static func isLiteralPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(where: { "*?[]{}|^$".contains($0) }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let target = path.hasSuffix("/") ? String(path.dropLast()) : path
        return !target.isEmpty && target.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    internal static func load(_ source: VaultFS.Handle, mode: CheckpointMode = .vaultContent) throws -> (scope: CheckpointScope, unsupported: [String]) {
        let data: Data?
        if let folderInfo = try VaultFS.entryInfo(source, ".planisphere") {
            guard folderInfo.st_mode & S_IFMT == S_IFDIR else {
                throw VaultStoreError.invalid("Planisphere settings must be a real folder before reviewing vault content.")
            }
            let settings = try VaultFS.childDirectory(source, ".planisphere")
            if try VaultFS.entryInfo(settings, "scope.json") != nil {
                data = try readConfiguration(settings)
            } else { data = nil }
        } else { data = nil }
        var includedRules: [String] = [], unsupported: [String] = []
        if let data {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VaultStoreError.invalid("Planisphere scope.json is not a settings object. Whole Folder remains available.")
            }
            if let raw = object["excludedPaths"] {
                guard let filters = raw as? [Any], filters.count <= 4096 else {
                    throw VaultStoreError.invalid("Planisphere's excluded paths list is invalid or exceeds 4,096 rules.")
                }
                for filter in filters {
                    guard let value = filter as? String, isLiteralPath(value) else {
                        unsupported.append(String(describing: filter).prefix(4096).description)
                        continue
                    }
                    includedRules.append(value)
                }
            }
        }
        let scope = CheckpointScope(excludedPaths: Array(Set(includedRules)).sorted(), sourceConfigurationSHA256: data.map(VaultFS.hash), mode: mode)
        try scope.validate()
        return (scope, unsupported)
    }

    private static func readConfiguration(_ settings: VaultFS.Handle) throws -> Data {
        let file = try VaultFS.Handle(openat(settings.fd, "scope.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        let before = try VaultFS.info(file)
        let limit = 2 * 1024 * 1024
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= limit else {
            throw VaultStoreError.invalid("Planisphere scope.json must be a regular settings file under 2 MiB.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw VaultFS.unavailable("Could not read Planisphere exclusions") }
            if count == 0 { break }
            guard data.count + count <= limit else { throw VaultStoreError.invalid("Planisphere settings grew during review.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard VaultFS.Stamp(before) == VaultFS.Stamp(try VaultFS.info(file)), data.count == before.st_size else {
            throw VaultStoreError.changedDuringCapture
        }
        return data
    }
}

public struct CheckpointExclusion: Equatable, Sendable {
    public let path: String
    public let reason: String
}

public struct CheckpointPlan: Sendable {
    public let mode: CheckpointMode
    public let scope: CheckpointScope?
    public let fileCount: Int
    public let directoryCount: Int
    public let symbolicLinkCount: Int
    public let totalBytes: Int64
    public let excludedPathCount: Int
    public let excludedPaths: [CheckpointExclusion]
    public let unsupportedFilters: [String]
}

internal enum CheckpointScopePlanner {
    /// Metadata-only review; actual capture still reads and validates every included byte twice.
    static func plan(source: VaultFS.Handle, mode: CheckpointMode) throws -> CheckpointPlan {
        let configuration = mode != .wholeFolder ? try CheckpointScope.load(source, mode: mode) : nil
        let scope = configuration?.scope
        var files = 0, directories = 0, links = 0, excluded = 0
        var bytes: Int64 = 0
        var exclusions: [CheckpointExclusion] = []
        func walk(_ directory: VaultFS.Handle, prefix: String) throws {
            let before = try VaultFS.info(directory)
            for name in try VaultFS.names(directory) {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                try VaultFS.relative(path)
                guard let info = try VaultFS.entryInfo(directory, name) else { throw VaultStoreError.changedDuringCapture }
                let kind = info.st_mode & S_IFMT
                if let reason = scope?.exclusionReason(path, isDirectory: kind == S_IFDIR, isSymbolicLink: kind == S_IFLNK, isRegularFile: kind == S_IFREG) {
                    excluded += 1
                    if exclusions.count < 200 { exclusions.append(CheckpointExclusion(path: path, reason: reason)) }
                    continue
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if mode != .markdownOnly { directories += 1 }
                    guard files + directories + links <= 250_000 else { throw VaultStoreError.invalid("This folder exceeds the 250,000-entry checkpoint limit. Review Vault Content to leave excluded development folders out.") }
                    let child = try VaultFS.childDirectory(directory, name)
                    guard VaultFS.Stamp(info) == VaultFS.Stamp(try VaultFS.info(child)) else { throw VaultStoreError.changedDuringCapture }
                    let previousFiles = files
                    try walk(child, prefix: path)
                    if mode == .markdownOnly {
                        if files > previousFiles { directories += 1 }
                        else {
                            excluded += 1
                            if exclusions.count < 200 { exclusions.append(CheckpointExclusion(path: path, reason: "Folder contains no included Markdown files")) }
                        }
                    }
                case S_IFREG, S_IFLNK:
                    if info.st_mode & S_IFMT == S_IFLNK { links += 1 } else { files += 1 }
                    let (sum, overflow) = bytes.addingReportingOverflow(info.st_size)
                    guard !overflow, info.st_size >= 0 else { throw VaultStoreError.invalid("The checkpoint size cannot be represented.") }
                    bytes = sum
                default:
                    throw VaultStoreError.invalid("A special file cannot be checkpointed: \(path). No files were changed.")
                }
                guard files + directories + links <= 250_000 else { throw VaultStoreError.invalid("This folder exceeds the 250,000-entry checkpoint limit. Review Vault Content to leave excluded development folders out.") }
            }
            guard VaultFS.Stamp(before) == VaultFS.Stamp(try VaultFS.info(directory)) else { throw VaultStoreError.changedDuringCapture }
        }
        try walk(source, prefix: "")
        try scope?.verifySource(source)
        return CheckpointPlan(mode: mode, scope: scope, fileCount: files, directoryCount: directories,
                              symbolicLinkCount: links, totalBytes: bytes, excludedPathCount: excluded,
                              excludedPaths: exclusions, unsupportedFilters: configuration?.unsupported ?? [])
    }
}
