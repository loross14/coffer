import Foundation
import CryptoKit
import os

/// Encrypts and decrypts all files in a vault directory.
/// Tracks per-file state in a manifest for crash recovery.
public enum FileEncryptor {

    // MARK: - Encrypt Vault

    /// Encrypts every regular file in the vault directory.
    /// - Writes `.cfr` encrypted files, deletes originals
    /// - Maintains an atomic manifest for crash recovery
    /// - Calls `onProgress` after each file (fileIndex, totalFiles)
    public static func encryptVault(
        at path: String,
        vaultID: UUID,
        using key: SymmetricKey,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> EncryptionManifest {
        let vaultURL = URL(fileURLWithPath: path).standardizedFileURL
        let vaultPrefix = vaultURL.path.hasSuffix("/") ? vaultURL.path : vaultURL.path + "/"
        let files = try collectFiles(in: vaultURL)
        var manifest = EncryptionManifest(vaultID: vaultID)

        // Pre-populate manifest with all files (unencrypted state)
        manifest.files = files.map { fileURL in
            let filePath = fileURL.standardizedFileURL.path
            let relativePath = filePath.hasPrefix(vaultPrefix) ? String(filePath.dropFirst(vaultPrefix.count)) : fileURL.lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? UInt16) ?? 0o644
            return EncryptionManifest.FileEntry(
                relativePath: relativePath,
                originalSize: size,
                encryptedSize: 0,
                isEncrypted: false,
                nonce: Data(),
                tag: Data(),
                posixPermissions: perms
            )
        }

        // Write initial manifest
        try writeManifest(manifest, to: vaultURL)

        // Encrypt each file
        for (index, fileURL) in files.enumerated() {
            let plaintext = try Data(contentsOf: fileURL)
            let (sealed, nonce, tag) = try CryptoEngine.encrypt(data: plaintext, using: key)

            // Write encrypted file
            let encryptedURL = fileURL.appendingPathExtension(Constants.Files.encryptedExtension)
            try sealed.write(to: encryptedURL, options: .atomic)

            // Update manifest entry
            manifest.files[index] = EncryptionManifest.FileEntry(
                relativePath: manifest.files[index].relativePath,
                originalSize: manifest.files[index].originalSize,
                encryptedSize: Int64(sealed.count),
                isEncrypted: true,
                nonce: nonce,
                tag: tag,
                posixPermissions: manifest.files[index].posixPermissions
            )

            // Write updated manifest atomically after each file
            try writeManifest(manifest, to: vaultURL)

            // Secure-delete original
            try secureDelete(fileURL)

            onProgress?(index + 1, files.count)
        }

        // Drop Spotlight blocker
        let spotlightBlocker = vaultURL.appendingPathComponent(Constants.Files.spotlightBlockFile)
        FileManager.default.createFile(atPath: spotlightBlocker.path, contents: nil)

        manifest.status = .completed
        manifest.completedAt = Date()
        try writeManifest(manifest, to: vaultURL)

        Log.fileOps.info("Encrypted \(files.count) files in vault \(vaultID)")
        return manifest
    }

    // MARK: - Decrypt Vault

    /// Decrypts all `.cfr` files back to their originals.
    /// Reads the manifest to know file metadata (permissions, etc).
    public static func decryptVault(
        at path: String,
        vaultID: UUID,
        using key: SymmetricKey,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws {
        let vaultURL = URL(fileURLWithPath: path).standardizedFileURL
        let manifest = try readManifest(from: vaultURL)

        let encryptedEntries = manifest.files.filter { $0.isEncrypted }

        for (index, entry) in encryptedEntries.enumerated() {
            let originalURL = vaultURL.appendingPathComponent(entry.relativePath)
            let encryptedURL = originalURL.appendingPathExtension(Constants.Files.encryptedExtension)

            guard FileManager.default.fileExists(atPath: encryptedURL.path) else {
                throw CofferError.encryptedFileMissing(entry.relativePath)
            }

            let sealedData = try Data(contentsOf: encryptedURL)
            let plaintext = try CryptoEngine.decrypt(combined: sealedData, using: key)

            // Write decrypted file atomically, then restore permissions
            try plaintext.write(to: originalURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: entry.posixPermissions)],
                ofItemAtPath: originalURL.path
            )

            // Remove encrypted file
            try FileManager.default.removeItem(at: encryptedURL)

            onProgress?(index + 1, encryptedEntries.count)
        }

        // Remove manifest and Spotlight blocker
        let manifestURL = vaultURL.appendingPathComponent(Constants.Files.manifestFilename)
        try? FileManager.default.removeItem(at: manifestURL)
        let spotlightBlocker = vaultURL.appendingPathComponent(Constants.Files.spotlightBlockFile)
        try? FileManager.default.removeItem(at: spotlightBlocker)

        Log.fileOps.info("Decrypted \(encryptedEntries.count) files in vault \(vaultID)")
    }

    // MARK: - File Collection

    /// Collects all regular files in a directory tree.
    /// Skips: symlinks, `.DS_Store`, the manifest file, Spotlight blocker, and `.cfr` files.
    public static func collectFiles(in directoryURL: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CofferError.cannotEnumerateDirectory
        }

        let skipNames: Set<String> = [
            ".DS_Store",
            Constants.Files.manifestFilename,
            Constants.Files.spotlightBlockFile,
        ]

        var files: [URL] = []

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])

            // Skip symlinks
            if resourceValues.isSymbolicLink == true { continue }
            // Skip non-regular files
            guard resourceValues.isRegularFile == true else { continue }
            // Skip our own metadata files
            if skipNames.contains(fileURL.lastPathComponent) { continue }
            // Skip already-encrypted files
            if fileURL.pathExtension == Constants.Files.encryptedExtension { continue }

            files.append(fileURL)
        }

        return files.sorted { $0.path < $1.path }
    }

    /// Collects encrypted `.cfr` files for decryption scanning.
    public static func collectEncryptedFiles(in directoryURL: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw CofferError.cannotEnumerateDirectory
        }

        var files: [URL] = []

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == Constants.Files.encryptedExtension {
                files.append(fileURL)
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Manifest I/O

    /// Writes the manifest atomically to the vault directory.
    public static func writeManifest(_ manifest: EncryptionManifest, to vaultURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let manifestURL = vaultURL.appendingPathComponent(Constants.Files.manifestFilename)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Reads the manifest from a vault directory.
    public static func readManifest(from vaultURL: URL) throws -> EncryptionManifest {
        let manifestURL = vaultURL.appendingPathComponent(Constants.Files.manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CofferError.manifestCorrupted
        }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(EncryptionManifest.self, from: data)
        } catch {
            throw CofferError.manifestCorrupted
        }
    }

    /// Checks if a vault directory has an interrupted encryption manifest.
    public static func hasInterruptedManifest(at path: String) -> Bool {
        let vaultURL = URL(fileURLWithPath: path).standardizedFileURL
        guard let manifest = try? readManifest(from: vaultURL) else {
            return false
        }
        return manifest.status == .inProgress || manifest.status == .interrupted
    }

    // MARK: - Vault Stats

    /// Returns (fileCount, totalSize) for a vault directory.
    public static func vaultStats(at path: String) throws -> (fileCount: Int, totalSize: Int64) {
        let vaultURL = URL(fileURLWithPath: path).standardizedFileURL
        let files = try collectFiles(in: vaultURL)
        var totalSize: Int64 = 0
        for file in files {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            totalSize += (attrs[.size] as? Int64) ?? 0
        }
        return (files.count, totalSize)
    }

    // MARK: - Open File Handle Check

    /// Checks if any files in the vault are open by another process.
    /// Uses `lsof` to detect open handles.
    public static func openFileHandles(in path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["+D", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return []
        }

        // Parse lsof output — skip header line, extract file paths
        let lines = output.components(separatedBy: "\n").dropFirst()
        var openFiles: Set<String> = []
        for line in lines where !line.isEmpty {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            if let lastCol = columns.last {
                let filePath = String(lastCol)
                if filePath.hasPrefix(path) {
                    openFiles.insert(filePath)
                }
            }
        }

        return Array(openFiles).sorted()
    }

    // MARK: - Secure Delete

    /// Overwrites file contents with random bytes before deletion.
    /// Best-effort on APFS/SSD (wear leveling limits true secure delete).
    public static func secureDelete(_ fileURL: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int) ?? 0

        if fileSize > 0, let handle = try? FileHandle(forWritingTo: fileURL) {
            // Overwrite with random bytes in 64KB chunks
            let chunkSize = 65_536
            var remaining = fileSize
            handle.seek(toFileOffset: 0)
            while remaining > 0 {
                let writeSize = min(chunkSize, remaining)
                let randomData = Data((0..<writeSize).map { _ in UInt8.random(in: 0...255) })
                handle.write(randomData)
                remaining -= writeSize
            }
            handle.synchronizeFile()
            handle.closeFile()
        }

        try FileManager.default.removeItem(at: fileURL)
    }
}
