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
    if let gh = ghBinaryPath() {
        let result = shell("\(gh) auth token", timeout: 10)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.hasPrefix("error") { return trimmed }
    }
    // 3. GH_TOKEN env var
    if let envToken = ProcessInfo.processInfo.environment["GH_TOKEN"],
       !envToken.isEmpty { return envToken }
    // 4. GITHUB_TOKEN env var
    if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
       !envToken.isEmpty { return envToken }
    return nil
}
