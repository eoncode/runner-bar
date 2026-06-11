// RunnerConfig.swift
// RunnerBarCore

// MARK: - RunnerConfig

/// Typed, `Codable` representation of the `.runner` JSON configuration file
/// written to each runner's install directory by the GitHub Actions runner agent.
///
/// Replaces the previous `[String: Any]` / `JSONSerialization` pattern used in
/// `RunnerEditDraft`, `CommitRunnerEdit`, and ad-hoc display-field reads.
/// All read/write access goes through `RunnerConfigStore` or `JSONDecoder`-based
/// typed wrappers — do **not** call `JSONSerialization` directly for runner config.
///
/// - Note: Part of Phase 3 of the Swift 6.2 data model modernisation (#1287, #1298).
public struct RunnerConfig: Codable, Sendable {

    // MARK: - Properties

    /// Absolute path to the runner's work folder.
    public var workFolder: String

    /// Whether automatic self-update is disabled for this runner.
    public var disableUpdate: Bool

    /// Platform identifier (e.g. `"linux"`, `"osx"`).
    public var platform: String?

    /// CPU architecture (e.g. `"x64"`, `"arm64"`).
    public var platformArchitecture: String?

    /// Version string of the installed runner agent.
    public var agentVersion: String?

    /// Whether the runner is configured in ephemeral (single-job) mode.
    public var ephemeral: Bool?

    /// Numeric agent ID assigned by GitHub.
    public var agentId: Int?

    // MARK: - CodingKeys

    /// Maps Swift property names to the PascalCase JSON keys written by the runner agent.
    ///
    /// The agent uses PascalCase for almost all keys. `disableUpdate` maps to `"DisableUpdate"`;
    /// `workFolder` maps to `"WorkFolder"`, and so on.
    public enum CodingKeys: String, CodingKey {
        case workFolder           = "WorkFolder"
        case disableUpdate        = "DisableUpdate"
        case platform             = "Platform"
        case platformArchitecture = "PlatformArchitecture"
        case agentVersion         = "AgentVersion"
        case ephemeral            = "Ephemeral"
        case agentId              = "AgentId"
    }

    // MARK: - Init

    /// Creates a `RunnerConfig` with the given values.
    public init(
        workFolder: String,
        disableUpdate: Bool,
        platform: String? = nil,
        platformArchitecture: String? = nil,
        agentVersion: String? = nil,
        ephemeral: Bool? = nil,
        agentId: Int? = nil
    ) {
        self.workFolder = workFolder
        self.disableUpdate = disableUpdate
        self.platform = platform
        self.platformArchitecture = platformArchitecture
        self.agentVersion = agentVersion
        self.ephemeral = ephemeral
        self.agentId = agentId
    }
}
