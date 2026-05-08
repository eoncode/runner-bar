import Foundation

// MARK: - Keychain

/// Thin wrapper around the `security` CLI for storing and retrieving
/// a GitHub OAuth token in the macOS Keychain.
///
/// Uses `security` instead of Security.framework so the binary works
/// without any entitlements or an Apple Developer account.
enum Keychain {
    /// The service name used for all keychain items.
    private static let service = "dev.eonist.runnerbar"
    /// The account name for the stored GitHub OAuth token.
    private static let account = "github-oauth-token"

    // MARK: - Read

    /// Returns the stored OAuth token, or `nil` if none is found.
    static func token() -> String? {
        let result = shell(
            "security find-generic-password -s \"\(service)\" -a \"\(account)\" -w",
            timeout: 5
        )
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("security:") ? nil : trimmed
    }

    // MARK: - Write

    /// Stores `token` in the keychain, replacing any previous value.
    /// Returns `true` on success.
    @discardableResult
    static func save(token: String) -> Bool {
        // Delete any existing item first so the add never conflicts.
        delete()
        let result = shell(
            "security add-generic-password -s \"\(service)\" -a \"\(account)\" -w \"\(token)\"",
            timeout: 5
        )
        let success = !result.lowercased().contains("error")
        log("Keychain.save › success=\(success)")
        return success
    }

    // MARK: - Delete

    /// Removes the stored token from the keychain.
    @discardableResult
    static func delete() -> Bool {
        let result = shell(
            "security delete-generic-password -s \"\(service)\" -a \"\(account)\"",
            timeout: 5
        )
        // exit 44 = item not found — treat as success.
        let success = result.isEmpty || result.lowercased().contains("deleted")
            || result.lowercased().contains("44")
        log("Keychain.delete › success=\(success)")
        return success
    }
}
