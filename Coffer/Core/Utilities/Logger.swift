import os

public enum Log {
    public static let crypto = Logger(subsystem: Constants.bundleID, category: "crypto")
    public static let keychain = Logger(subsystem: Constants.bundleID, category: "keychain")
    public static let auth = Logger(subsystem: Constants.bundleID, category: "auth")
    public static let vault = Logger(subsystem: Constants.bundleID, category: "vault")
    public static let fileOps = Logger(subsystem: Constants.bundleID, category: "fileOps")
    public static let autoLock = Logger(subsystem: Constants.bundleID, category: "autoLock")
    public static let ui = Logger(subsystem: Constants.bundleID, category: "ui")
    public static let passkey = Logger(subsystem: Constants.bundleID, category: "passkey")
}
