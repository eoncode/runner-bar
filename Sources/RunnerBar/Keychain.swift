import Foundation
import Security

// MARK: - Keychain
//
// Stores and retrieves the OAuth token using the native SecItem API.
// Replaces the previous `security` CLI subprocess implementation (#605).
//
// kSecAttrService / kSecAttrAccount identify the item; kSecAttrAccessible
// is set to .afterFirstUnlock so the token survives device sleep while
// still being protected at rest.

enum Keychain {
    private static let service = "runner-bar" as CFString
    private static let account = "github-oauth-token" as CFString
    private static let accessible = kSecAttrAccessibleAfterFirstUnlock

    // MARK: - Base query

    private static var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }

    // MARK: - Read

    /// The stored OAuth token, or nil if none is present.
    static var token: String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token.isEmpty ? nil : token
    }

    // MARK: - Write

    /// Saves (or overwrites) the token and invalidates the in-memory token cache.
    static func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        if SecItemCopyMatching(baseQuery as CFDictionary, nil) == errSecSuccess {
            // Item exists — update it.
            let attributes: [CFString: Any] = [kSecValueData: data]
            SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        } else {
            // No existing item — add it.
            var newItem = baseQuery
            newItem[kSecValueData] = data
            newItem[kSecAttrAccessible] = accessible
            SecItemAdd(newItem as CFDictionary, nil)
        }
        invalidateTokenCache()
    }

    // MARK: - Delete

    /// Deletes the stored token and invalidates the in-memory token cache.
    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
        invalidateTokenCache()
    }
}
