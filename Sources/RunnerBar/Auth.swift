import Foundation

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. macOS Keychain (via `security` CLI) — native OAuth token stored by `OAuthService`.
/// 2. `gh auth token` — silent fallback so existing `gh`-authenticated users are never broken.
/// 3. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 4. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source.
func githubToken() -> String? {
    // 1. Keychain — native OAuth (issue #326)
    if let token = Keychain.token() { return token }
    // 2. gh CLI fallback — keeps existing users working without re-auth
    if let ghPath = ghBinaryPath() {
        let result = shell("\(ghPath) auth token", timeout: 10)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidGitHubToken(trimmed) { return trimmed }
    }
    // 3. GH_TOKEN env var
    if let envToken = ProcessInfo.processInfo.environment["GH_TOKEN"],
       !envToken.isEmpty { return envToken }
    // 4. GITHUB_TOKEN env var
    if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
       !envToken.isEmpty { return envToken }
    return nil
}

/// Returns `true` when `token` looks like a real GitHub credential.
///
/// Validates against all known GitHub token prefixes and the legacy 40-char
/// hex classic-PAT format. Rejects shell error strings such as
/// `"zsh: command not found: gh"` or `"/opt/homebrew/bin/gh: No such file"`
/// that `gh auth token` can emit when the binary is missing or misconfigured.
private func isValidGitHubToken(_ token: String) -> Bool {
    guard !token.isEmpty else { return false }
    let knownPrefixes = ["ghp_", "ghs_", "ghu_", "ghr_", "github_pat_"]
    if knownPrefixes.contains(where: { token.hasPrefix($0) }) { return true }
    // Legacy 40-char lowercase hex token (classic PAT before prefix era).
    if token.count == 40 && token.allSatisfy({ $0.isHexDigit }) { return true }
    return false
}
