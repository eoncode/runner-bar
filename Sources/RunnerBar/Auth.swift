import Foundation

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. `gh auth token` — preferred; uses the active authenticated `gh` CLI session.
/// 2. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 3. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source.
func githubToken() -> String? {
    // ghBinaryPath() searches common install locations; avoids a hard-coded path (S1075).
    guard let ghPath = ghBinaryPath() else {
        if let envToken = ProcessInfo.processInfo.environment["GH_TOKEN"],
           !envToken.isEmpty { return envToken }
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
           !envToken.isEmpty { return envToken }
        return nil
    }
    let result = shell("\(ghPath) auth token", timeout: 10)
    if !result.isEmpty && !result.hasPrefix("error") { return result }
    if let envToken = ProcessInfo.processInfo.environment["GH_TOKEN"],
       !envToken.isEmpty { return envToken }
    if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
       !envToken.isEmpty { return envToken }
    return nil
}
