import Foundation

// MARK: - Keychain

/// Thin wrapper around the `security` CLI for storing and retrieving
/// a GitHub OAuth token in the macOS Keychain.
///
/// Uses `security` instead of Security.framework so the binary works
/// without any entitlements or an Apple Developer account.
///
/// ⚠️ All `security` invocations use direct Process argument arrays —
/// the token value is NEVER interpolated into a shell string to prevent
/// shell injection. (ref: review issue #1, PR #341)
enum Keychain {
    /// The service name used for all keychain items.
    private static let service = "dev.eonist.runnerbar"
    /// The account name for the stored GitHub OAuth token.
    private static let account = "github-oauth-token"
    /// Absolute path to the `security` binary.
    private static let securityPath = "/usr/bin/security"

    // MARK: - Private helpers

    /// Runs `security` with the given arguments using a direct Process
    /// argument array (no shell, no interpolation). Returns trimmed stdout.
    private static func runSecurity(args: [String], timeout: TimeInterval = 5) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: securityPath)
        task.arguments = args
        task.standardOutput = pipe
        task.standardError  = pipe
        do {
            try task.run()
        } catch {
            log("Keychain.runSecurity › launch error: \(error)")
            return ""
        }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline { task.terminate(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Read

    /// Returns the stored OAuth token, or `nil` if none is found.
    static func token() -> String? {
        let result = runSecurity(args: [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w"
        ])
        return result.isEmpty || result.hasPrefix("security:") ? nil : result
    }

    // MARK: - Write

    /// Stores `token` in the keychain, replacing any previous value.
    /// The token is passed as a discrete argument — never shell-interpolated.
    /// Returns `true` on success.
    @discardableResult
    static func save(token: String) -> Bool {
        // Delete any existing item first so the add never conflicts.
        delete()
        let result = runSecurity(args: [
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-w", token          // ← argv element, not shell string
        ])
        let success = !result.lowercased().contains("error")
        log("Keychain.save › success=\(success)")
        return success
    }

    // MARK: - Delete

    /// Removes the stored token from the keychain.
    @discardableResult
    static func delete() -> Bool {
        let result = runSecurity(args: [
            "delete-generic-password",
            "-s", service,
            "-a", account
        ])
        // exit 44 = item not found — treat as success.
        let success = result.isEmpty || result.lowercased().contains("deleted")
            || result.contains("44")
        log("Keychain.delete › success=\(success)")
        return success
    }
}
