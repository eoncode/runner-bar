import Foundation
import Security

// MARK: - Keychain
//
// Wraps Security.framework to store and retrieve the OAuth token.
// Uses SecItemUpdate/SecItemAdd (upsert pattern) with errSecDuplicateItem
// retry guard, SecItemCopyMatching, and SecItemDelete.

enum Keychain {
    private static let service = "runner-bar"
    private static let account = "github-oauth-token"

    // MARK: - Private helpers

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: - Public API

    /// The stored OAuth token, or nil if none is present.
    static var token: String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token.isEmpty ? nil : token
    }

    /// Saves (or overwrites) the token and invalidates the in-memory token cache.
    /// Returns true if the token was successfully persisted.
    @discardableResult
    static func save(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        // Try update first; fall back to add if item does not exist.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        var succeeded = updateStatus == errSecSuccess
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            // kSecAttrAccessibleAfterFirstUnlock: token is readable after the first
            // unlock post-reboot, which covers app launch in the background before
            // the user has unlocked the screen. Without this, the default
            // kSecAttrAccessibleWhenUnlocked would block token reads at launch.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // A concurrent writer inserted the item between our update and add.
                // Retry the update now that the item exists.
                let retryStatus = SecItemUpdate(
                    baseQuery() as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                if retryStatus == errSecSuccess { succeeded = true } else { log("Keychain.save › retry SecItemUpdate failed: \(retryStatus)") }
            } else if addStatus == errSecSuccess {
                succeeded = true
            } else {
                log("Keychain.save › SecItemAdd failed: \(addStatus)")
            }
        } else if !succeeded {
            log("Keychain.save › SecItemUpdate failed: \(updateStatus)")
        }
        if succeeded { invalidateTokenCache() }
        return succeeded
    }

    /// Deletes the stored token.
    /// Invalidates the in-memory token cache only when deletion actually succeeds
    /// (or the item was already absent). Returns true on success.
    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        let succeeded = status == errSecSuccess || status == errSecItemNotFound
        if !succeeded {
            log("Keychain.delete › SecItemDelete failed: \(status)")
            return false
        }
        invalidateTokenCache()
        return true
    }
}
