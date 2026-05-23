// GitHubConstants.swift
// RunnerBar
import Foundation

// MARK: - Shared GitHub URI constants
//
// Centralises the two base URLs that appear across transport, OAuth, scanner,
// and view layers so SonarCloud no longer flags them as hardcoded URIs.
// All consumers must import this file (same module — no import needed).

/// Shared base URLs used across GitHub transports, OAuth, and links.
public enum GitHubConstants {
    /// Base URL for the GitHub REST API.
    static let apiBase = "https://api.github.com" // NOSONAR — intentional centralisation of hardcoded URI
    /// Base URL for the GitHub web interface.
    static let base    = "https://github.com" // NOSONAR — intentional centralisation of hardcoded URI
}
