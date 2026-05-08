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
    /// Uses Process to pass the token as a discrete argument — never interpolated into
    /// a shell string — so the credential cannot appear in logs or process listings.
    @discardableResult
    static func write(_ token: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-w", token,
            "-U"
        ]
        // Suppress stderr — "security: SecKeychainItemModifyContent" noise on update.
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            log("KeychainHelper › write failed: \(error)")
            return false
        }
    }

    /// Deletes the token from the Keychain. No-op if the entry does not exist.
    static func delete() {
        shell(
            "security delete-generic-password -s \(service) -a \(account) 2>/dev/null",
            timeout: 5
        )
    }
}
