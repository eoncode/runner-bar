import Foundation

// MARK: - KeychainHelper

/// Thin wrapper around the macOS `security` CLI for reading, writing,
/// and deleting a generic password entry in the login Keychain.
///
/// Uses no `Security.framework` imports, no entitlements, and no
/// code-signing changes — the same approach used by `gh` itself and Tauri apps.
/// Compatible with both Apple Silicon and Intel Homebrew prefixes.
enum KeychainHelper {
    /// The service name used as the Keychain item identifier.
    static let service = "runner-bar"
    /// The account name used as the Keychain item identifier.
    static let account = "github-token"

    /// Reads the stored token from the Keychain.
    /// Returns `nil` if no entry exists or the read fails.
    static func read() -> String? {
        let out = shell(
            "security find-generic-password -s \(service) -a \(account) -w 2>/dev/null",
            timeout: 5
        )
        return out.isEmpty ? nil : out
    }

    /// Writes (or overwrites) the token in the Keychain using the `-U` update flag.
    static func write(_ token: String) {
        // -U: update if the item already exists, add otherwise.
        shell(
            "security add-generic-password -s \(service) -a \(account) -w \(token) -U 2>/dev/null",
            timeout: 5
        )
    }

    /// Deletes the token from the Keychain. No-op if the entry does not exist.
    static func delete() {
        shell(
            "security delete-generic-password -s \(service) -a \(account) 2>/dev/null",
            timeout: 5
        )
    }
}
