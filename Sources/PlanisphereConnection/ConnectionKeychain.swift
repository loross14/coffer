import Foundation
import Security

public protocol ConnectionCredentialStoring {
    func read() throws -> ConnectionCredential?
    func save(_ value: ConnectionCredential) throws
    func remove() throws
}

public struct ConnectionKeychain: ConnectionCredentialStoring {
    // One fixed origin per credential. No credential follows configurable server addresses.
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ooo.planisphere.mac.console",
        kSecAttrAccount as String: "https://api.planisphere.ooo",
        kSecAttrSynchronizable as String: false,
    ]
    public init() {}
    public func read() throws -> ConnectionCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = data as? Data else { throw ConnectionError.keychain(status) }
        return try JSONDecoder().decode(ConnectionCredential.self, from: data)
    }
    public func save(_ value: ConnectionCredential) throws {
        let bytes = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: bytes]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = bytes
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw ConnectionError.keychain(added) }
        } else if status != errSecSuccess { throw ConnectionError.keychain(status) }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectionError.keychain(status) }
    }
}
