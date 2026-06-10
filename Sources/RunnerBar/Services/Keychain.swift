// Keychain.swift
// RunnerBar
import Foundation
import Security

// MARK: - Keychain
//
// Wraps Security.framework to store and retrieve the OAuth token.
// Uses SecItemUpdate/SecItemAdd (upsert pattern) with errSecDuplicateItem
// retry guard, SecItemCopyMatching, and SecItemDelete.
//
// kSecUseDataProtectionKeychain: true forces all operations through the modern
// Data Protection Keychain, bypassing the legacy CSSM-based keychain entirely.
// Without this, SecItemCopyMatching can trigger a C++ CSSMERR_DL_DATASTORE_DOESNOT_EXIST
// exception that crashes the process on launch when the legacy keychain DB file
// is missing or was created under a different signing identity.

/// Wrapper around Security.framework for storing and retrieving the GitHub OAuth token.
enum Keychain {
    /// Keychain service name used for RunnerBar credentials.
    private static let service = "runner-bar"
    /// Keychain account name used for the stored OAuth token.
    private static let account = "github-oauth-token"

    // MARK: - Private helpers

    /// Returns the base Keychain query shared by all token operations.
    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
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
        // kSecAttrAccessibleAfterFirstUnlock is included on both paths so that a
        // legacy item created without this attribute (e.g. from an older build or
        // different signing identity) is upgraded in place. Without it, the existing
        // accessibility attribute is preserved, and a legacy item may be inaccessible
        // at launch before the first device unlock.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ] as CFDictionary
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
                    [
                        kSecValueData as String: data,
                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                    ] as CFDictionary
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
