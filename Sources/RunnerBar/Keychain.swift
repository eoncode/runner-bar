import Foundation

// MARK: - Keychain
//
// Wraps the macOS `security` CLI to store and retrieve the OAuth token.
// Using the CLI (rather than Security.framework directly) avoids the need
// for entitlements or an Apple Developer signing identity — keeping the
// existing curl-install / unsigned build flow intact.

enum Keychain {
    private static let service = "runner-bar"
    private static let account = "github-oauth-token"

    static var token: String? {
        let result = shell("/usr/bin/security find-generic-password -s \(service) -a \(account) -w 2>/dev/null")
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ token: String) {
        let escaped = token.replacingOccurrences(of: "'", with: "'\\''")
        _ = shell("/usr/bin/security add-generic-password -s \(service) -a \(account) -w '\(escaped)' -U 2>/dev/null")
    }

    static func delete() {
        _ = shell("/usr/bin/security delete-generic-password -s \(service) -a \(account) 2>/dev/null")
    }
}
