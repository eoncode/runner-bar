// GitHubURLHelpers.swift
// RunnerBarCore
import Foundation

// MARK: - GitHub URL utilities

/// Extracts the `owner/repo` or `orgName` scope string from a GitHub HTML URL.
///
/// - For repo-scoped URLs (`https://github.com/owner/repo`) returns `"owner/repo"`.
/// - For org-scoped URLs (`https://github.com/myorg`) returns `"myorg"`.
/// - Returns `nil` if `urlString` is nil, not a valid URL, or has no path components.
///
/// This is the canonical implementation shared by `SaveRunnerEditsUseCase` (RunnerBarCore)
/// and the app-target helpers (`GitHubHelpers.swift`). The previous private copy inside
/// `SaveRunnerEditsUseCase` and the older app-target copy diverged in their handling of
/// org-scoped URLs — this version correctly handles both by checking `parts.count`.
///
/// - Note: `pathComponents` on `URL` includes `"/"` as the first component for absolute
///   URLs; the filter step removes it so index 0 is always the owner/org name.
public func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString) else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    if parts.count >= 2 { return parts[0] + "/" + parts[1] }
    if parts.count == 1 { return parts[0] }
    return nil
}
