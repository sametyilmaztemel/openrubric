import Foundation
import Security

/// Minimal Keychain wrapper for the BYO API key.
///
/// The key is the only secret; everything else (base URL, model, crop
/// radius, hotkey) is non-secret and lives in UserDefaults.
enum KeychainStore {
    private static let service = "com.sametyilmaztemel.openrubric"
    private static let account = "api-key"

    enum KeychainError: Swift.Error, LocalizedError {
        case itemError(OSStatus)

        var errorDescription: String? {
            if case .itemError(let status) = self {
                return "Keychain operation failed (status \(status))."
            }
            return nil
        }
    }

    /// Saves the key, or deletes the item when the key is empty.
    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete()
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            for (k, v) in attributes { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.itemError(addStatus)
            }
        default:
            throw KeychainError.itemError(status)
        }
    }

    /// Returns the stored key, or `nil` when none is set.
    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
