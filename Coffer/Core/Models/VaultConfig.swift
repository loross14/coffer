import Foundation

public struct VaultConfig: Codable, Sendable {
    public var vaults: [Vault]
    public var globalSettings: GlobalSettings

    public init(vaults: [Vault] = [], globalSettings: GlobalSettings = GlobalSettings()) {
        self.vaults = vaults
        self.globalSettings = globalSettings
    }
}

public struct GlobalSettings: Codable, Sendable {
    public var autoLockOnSleep: Bool
    public var autoLockOnScreenLock: Bool
    public var defaultAutoLockMinutes: Int
    public var showMenubarIcon: Bool
    public var showDockIcon: Bool

    public init(
        autoLockOnSleep: Bool = true,
        autoLockOnScreenLock: Bool = true,
        defaultAutoLockMinutes: Int = 5,
        showMenubarIcon: Bool = true,
        showDockIcon: Bool = true
    ) {
        self.autoLockOnSleep = autoLockOnSleep
        self.autoLockOnScreenLock = autoLockOnScreenLock
        self.defaultAutoLockMinutes = defaultAutoLockMinutes
        self.showMenubarIcon = showMenubarIcon
        self.showDockIcon = showDockIcon
    }
}
