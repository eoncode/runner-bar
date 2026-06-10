// RunnerConfig.swift
// RunnerBarCore

// MARK: - RunnerConfig

/// Typed, `Codable` representation of the `.runner` JSON configuration file
/// written to each runner's install directory by the GitHub Actions runner agent.
///
/// Replaces the previous `[String: Any]` / `JSONSerialization` pattern used in
/// `RunnerEditDraft`, `RunnerEditCommit`, and `RunnerModel`. All read/write access
/// goes through `RunnerConfigStore` — do **not** call `JSONSerialization` directly.
///
/// - Note: Part of Phase 3 of the Swift 6.2 data model modernisation (#1287, #1298).
struct RunnerConfig: Codable, Sendable {

    // MARK: - Properties

    /// Absolute path to the runner's work folder.
    var workFolder: String

    /// Whether automatic self-update is disabled for this runner.
    var disableUpdate: Bool

    /// Platform identifier (e.g. `"linux"`, `"osx"`).
    var platform: String?

    /// CPU architecture (e.g. `"x64"`, `"arm64"`).
    var platformArchitecture: String?

    /// Version string of the installed runner agent.
    var agentVersion: String?

    /// Whether the runner is configured in ephemeral (single-job) mode.
    var ephemeral: Bool?

    /// Numeric agent ID assigned by GitHub.
    var agentId: Int?
}
