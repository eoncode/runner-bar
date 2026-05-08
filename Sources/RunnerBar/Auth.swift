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
    // 2. gh CLI fallback — keeps existing users working unchanged
    let ghResult = shell("\(ghBinaryPath() ?? "/opt/homebrew/bin/gh") auth token", timeout: 10)
    if !ghResult.isEmpty && !ghResult.hasPrefix("error") { return ghResult }
    // 3. GH_TOKEN env var — CI / scripted contexts
    if let envToken = ProcessInfo.processInfo.environment["GH_TOKEN"],
       !envToken.isEmpty { return envToken }
    // 4. GITHUB_TOKEN env var — Actions-style fallback
    if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
       !envToken.isEmpty { return envToken }
    return nil
}
