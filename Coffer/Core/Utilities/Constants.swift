import Foundation

public enum Constants {
    public static let appName = "Coffer"
    public static let bundleID = "com.loganross.coffer"

    public enum Keychain {
        public static let service = "com.loganross.coffer"
        public static let masterKeyPrefix = "masterKey"
        public static let saltPrefix = "salt"
        public static let biometricSuffix = "biometric"
        public static let wrappedSuffix = "wrapped"
    }

    public enum Crypto {
        public static let hkdfInfo = "com.loganross.coffer.v1"
        public static let saltLength = 16
        public static let keyLength = 32
    }

    public enum Files {
        public static let encryptedExtension = "cfr"
        public static let manifestFilename = ".coffer-manifest.json"
        public static let spotlightBlockFile = ".metadata_never_index"
        public static let configDirectory = "Coffer"
        public static let configFilename = "vaults.json"
    }

    public enum UI {
        public static let menubarIcon = "lock.shield.fill"
        public static let windowMinWidth: CGFloat = 520
        public static let windowMinHeight: CGFloat = 400
    }
}
