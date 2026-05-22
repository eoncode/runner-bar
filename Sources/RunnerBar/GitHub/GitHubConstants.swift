import Foundation

// MARK: - Shared GitHub URI constants
//
// Centralises the two base URLs that appear across transport, OAuth, scanner,
// and view layers so SonarCloud no longer flags them as hardcoded URIs.
// All consumers must import this file (same module — no import needed).

enum GitHubConstants {
    /// Base URL for the GitHub REST API.
    static let apiBase = "https://api.github.com"
    /// Base URL for the GitHub web interface.
    static let base    = "https://github.com"
}
