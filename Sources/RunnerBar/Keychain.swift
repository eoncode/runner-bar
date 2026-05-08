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
/// shell injection. Exit status is read from `terminationStatus` after
/// `waitUntilExit()` — not from stderr substrings.
enum Keychain {
    /// The service name used for all keychain items.
    private static let service = "dev.eonist.runnerbar"
    /// The account name for the stored GitHub OAuth token.
    private static let account = "github-oauth-token"
    /// Absolute path to the `security` binary.
    private static let securityPath = "/usr/bin/security"

    // MARK: - Private helpers

    /// Result of a `security` invocation.
    private struct SecurityResult {
        /// Trimmed stdout+stderr output.
        let output: String
        /// Process exit status (0 = success, 44 = item not found, etc.).
        let status: Int32
    }

    /// Runs `security` with the given arguments using a direct Process argument
    /// array (no shell, no interpolation). Blocks until exit or timeout.
    private static func runSecurity(args: [String], timeout: TimeInterval = 5) -> SecurityResult {
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
            return SecurityResult(output: "", status: -1)
        }
        // Enforce timeout; fall back to waitUntilExit for the normal path.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        task.waitUntilExit()  // ensure terminationStatus is populated
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SecurityResult(output: output, status: task.terminationStatus)
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
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return result.output
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
        let success = result.status == 0
        log("Keychain.save › status=\(result.status) success=\(success)")
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
        // exit 0 = deleted, exit 44 = item not found (treat as success).
        let success = result.status == 0 || result.status == 44
        log("Keychain.delete › status=\(result.status) success=\(success)")
        return success
    }
}
