import Foundation
import CryptoKit
import os

/// Singleton orchestrator for vault lifecycle: add, lock, unlock, remove.
/// Persists vault config to ~/Library/Application Support/Coffer/vaults.json.
@MainActor
public final class VaultManager {

    public static let shared = VaultManager()

    public let authService = AuthService()
    public private(set) var config: VaultConfig

    private let configURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cofferDir = appSupport.appendingPathComponent(Constants.Files.configDirectory)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: cofferDir, withIntermediateDirectories: true)

        configURL = cofferDir.appendingPathComponent(Constants.Files.configFilename)
        config = VaultManager.loadConfig(from: configURL)

        Log.vault.info("VaultManager initialized with \(self.config.vaults.count) vaults")
    }

    /// For testing — allows injection of a custom config path.
    public init(configURL: URL) {
        self.configURL = configURL
        config = VaultManager.loadConfig(from: configURL)
    }

    public var vaults: [Vault] { config.vaults }
    public var settings: GlobalSettings { config.globalSettings }
    public var isBiometricsAvailable: Bool { authService.isBiometricsAvailable }

    // MARK: - Add Vault

    /// Registers a new vault with password + optional Touch ID.
    public func addVault(
        name: String,
        folderPath: String,
        password: String,
        useTouchID: Bool,
        autoLockMinutes: Int,
        lockImmediately: Bool = false
    ) throws -> Vault {
        // Verify directory exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            throw CofferError.vaultNotFound
        }

        // Get initial stats
        let (fileCount, totalSize) = try FileEncryptor.vaultStats(at: folderPath)

        var vault = Vault(
            name: name,
            folderPath: folderPath,
            state: .unlocked,
            autoLockMinutes: autoLockMinutes,
            useTouchID: useTouchID,
            fileCount: fileCount,
            totalSize: totalSize
        )

        // Setup crypto keys via AuthService
        _ = try authService.setupVault(
            vaultID: vault.id,
            password: password,
            enableTouchID: useTouchID
        )

        config.vaults.append(vault)
        try saveConfig()

        Log.vault.info("Added vault '\(name)' at \(folderPath)")

        if lockImmediately {
            try lockVault(vault.id, password: password)
            if let index = config.vaults.firstIndex(where: { $0.id == vault.id }) {
                vault = config.vaults[index]
            }
        }

        return vault
    }

    // MARK: - Lock Vault

    /// Locks a vault using the password-derived master key.
    public func lockVault(
        _ vaultID: UUID,
        password: String,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws {
        guard let index = config.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw CofferError.vaultNotFound
        }

        let vault = config.vaults[index]
        guard vault.state == .unlocked else { return }

        let openFiles = FileEncryptor.openFileHandles(in: vault.folderPath)
        if !openFiles.isEmpty {
            throw CofferError.filesInUse(openFiles)
        }

        config.vaults[index].state = .encrypting
        try saveConfig()

        let masterKey = try authService.unlockWithPassword(password, vaultID: vaultID)

        do {
            let manifest = try FileEncryptor.encryptVault(
                at: vault.folderPath,
                vaultID: vaultID,
                using: masterKey,
                onProgress: onProgress
            )

            config.vaults[index].state = .locked
            config.vaults[index].fileCount = manifest.files.count
            config.vaults[index].totalSize = manifest.files.reduce(0) { $0 + $1.originalSize }
            try saveConfig()

            Log.vault.info("Locked vault '\(vault.name)'")
        } catch {
            config.vaults[index].state = .error
            try? saveConfig()
            throw error
        }
    }

    // MARK: - Unlock Vault (Touch ID)

    /// Unlocks a vault using Touch ID to retrieve the master key from Keychain.
    public func unlockVaultWithBiometrics(
        _ vaultID: UUID,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws {
        guard let index = config.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw CofferError.vaultNotFound
        }

        let vault = config.vaults[index]
        guard vault.state == .locked else { return }

        config.vaults[index].state = .decrypting
        try saveConfig()

        do {
            let masterKey = try await authService.unlockWithBiometrics(
                vaultID: vaultID,
                vaultName: vault.name
            )

            try FileEncryptor.decryptVault(
                at: vault.folderPath,
                vaultID: vaultID,
                using: masterKey,
                onProgress: onProgress
            )

            config.vaults[index].state = .unlocked
            config.vaults[index].lastUnlockedAt = Date()
            let (fileCount, totalSize) = try FileEncryptor.vaultStats(at: vault.folderPath)
            config.vaults[index].fileCount = fileCount
            config.vaults[index].totalSize = totalSize
            try saveConfig()

            Log.vault.info("Unlocked vault '\(vault.name)' via Touch ID")
        } catch {
            config.vaults[index].state = .error
            try? saveConfig()
            throw error
        }
    }

    // MARK: - Unlock Vault (Password)

    /// Unlocks a vault using a password.
    public func unlockVaultWithPassword(
        _ vaultID: UUID,
        password: String,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws {
        guard let index = config.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw CofferError.vaultNotFound
        }

        let vault = config.vaults[index]
        guard vault.state == .locked else { return }

        let masterKey = try authService.unlockWithPassword(password, vaultID: vaultID)

        config.vaults[index].state = .decrypting
        try saveConfig()

        do {
            try FileEncryptor.decryptVault(
                at: vault.folderPath,
                vaultID: vaultID,
                using: masterKey,
                onProgress: onProgress
            )

            config.vaults[index].state = .unlocked
            config.vaults[index].lastUnlockedAt = Date()
            let (fileCount, totalSize) = try FileEncryptor.vaultStats(at: vault.folderPath)
            config.vaults[index].fileCount = fileCount
            config.vaults[index].totalSize = totalSize
            try saveConfig()

            Log.vault.info("Unlocked vault '\(vault.name)' via password")
        } catch {
            config.vaults[index].state = .error
            try? saveConfig()
            throw error
        }
    }

    // MARK: - Remove Vault

    /// Removes a vault from the app. If locked, decrypts first (requires password).
    /// Does NOT delete the original folder — just stops managing it.
    public func removeVault(_ vaultID: UUID, password: String? = nil) async throws {
        guard let index = config.vaults.firstIndex(where: { $0.id == vaultID }) else {
            throw CofferError.vaultNotFound
        }

        let vault = config.vaults[index]

        // If locked, must decrypt first
        if vault.state == .locked {
            if let password {
                try unlockVaultWithPassword(vaultID, password: password)
            } else if vault.useTouchID {
                try await unlockVaultWithBiometrics(vaultID)
            } else {
                throw CofferError.wrongPassword
            }
        }

        // Clean up Keychain entries
        KeychainService.deleteAllEntries(forVaultID: vaultID)

        config.vaults.remove(at: index)
        try saveConfig()

        Log.vault.info("Removed vault '\(vault.name)'")
    }

    // MARK: - Lock All

    /// Locks all unlocked vaults. Requires password for each.
    public func lockAllVaults(password: String) throws {
        for vault in config.vaults where vault.state == .unlocked {
            try lockVault(vault.id, password: password)
        }
    }

    // MARK: - Recovery

    /// Checks for any vaults with interrupted encryption and returns their IDs.
    public func interruptedVaults() -> [UUID] {
        config.vaults.compactMap { vault in
            FileEncryptor.hasInterruptedManifest(at: vault.folderPath) ? vault.id : nil
        }
    }

    // MARK: - Config Persistence

    private static func loadConfig(from url: URL) -> VaultConfig {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(VaultConfig.self, from: data) else {
            return VaultConfig()
        }
        return config
    }

    private func saveConfig() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: - Settings

    public func updateSettings(_ settings: GlobalSettings) throws {
        config.globalSettings = settings
        try saveConfig()
    }
}
