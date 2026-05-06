import Foundation

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. `gh auth token` — preferred; uses the active authenticated `gh` CLI session.
/// 2. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 3. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source, indicating the user
/// is not authenticated. Callers should check for `nil` and prompt sign-in.
func githubToken() -> String? {
    // 1. gh CLI
    let token = shell("/opt/homebrew/bin/gh auth token")
    if !token.isEmpty && !token.hasPrefix("error") {
        return token
    }
    // 2. GH_TOKEN env var
    if let ghToken = ProcessInfo.processInfo.environment["GH_TOKEN"], !ghToken.isEmpty {
        return ghToken
    }
    // 3. GITHUB_TOKEN env var
    if let githubToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !githubToken.isEmpty {
        return githubToken
    }
    return nil
}
