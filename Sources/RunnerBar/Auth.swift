import Foundation

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order (new users use 1, existing gh users fall through to 2):
/// 1. **Keychain** — native OAuth token written by `OAuthService` after browser sign-in.
/// 2. **`gh auth token`** — graceful fallback for users already authenticated via `gh` CLI.
/// 3. **`GH_TOKEN`** env var — CI / scripted contexts.
/// 4. **`GITHUB_TOKEN`** env var — GitHub Actions-style fallback.
///
/// Returns `nil` only if all four sources are empty.
/// Existing `gh`-authenticated users are **not** forced to re-authenticate.
func githubToken() -> String? {
    // 1. Keychain — native OAuth token (preferred for new users going forward)
    if let keychainToken = KeychainHelper.read(),
       !keychainToken.isEmpty {
        return keychainToken
    }
    // 2. gh CLI fallback — keeps existing users working unchanged.
    // Validate output looks like a real GitHub token to avoid treating shell errors
    // (e.g. "zsh: command not found") as credentials and blocking env-var fallbacks.
    let ghResult = shell("\(ghBinaryPath() ?? "/opt/homebrew/bin/gh") auth token", timeout: 10)
    if isValidGitHubToken(ghResult) { return ghResult }
    // 3. GH_TOKEN env var — CI / scripted contexts
    if let envToken = ProcessInfo.processInfo.environment["GH_TOKEN"],
       !envToken.isEmpty { return envToken }
    // 4. GITHUB_TOKEN env var — Actions-style fallback
    if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
       !envToken.isEmpty { return envToken }
    return nil
}

/// Returns true when the string looks like a real GitHub-issued token.
/// Accepts the known prefixes for OAuth (ghp_), server-to-server (ghs_),
/// user-to-server (ghu_), refresh (ghr_), fine-grained PATs (github_pat_),
/// and legacy 40-char hex tokens.
private func isValidGitHubToken(_ token: String) -> Bool {
    guard !token.isEmpty else { return false }
    let knownPrefixes = ["ghp_", "ghs_", "ghu_", "ghr_", "github_pat_"]
    if knownPrefixes.contains(where: { token.hasPrefix($0) }) { return true }
    // Legacy 40-char lowercase hex token (classic PAT before prefix era).
    if token.count == 40 && token.allSatisfy({ $0.isHexDigit }) { return true }
    return false
}
