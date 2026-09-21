import Foundation
import Security

protocol AccountStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// The token vault stays on this watch and is never included in iCloud backups.
struct KeychainAccountStorage: AccountStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "TinyCord.SavedAccounts",
         kSecAttrAccount as String: "accounts-v1"]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageError() }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError() }
    }

    struct StorageError: LocalizedError {
        var errorDescription: String? { "Couldn't access saved accounts. Unlock your watch and try again." }
    }
}
