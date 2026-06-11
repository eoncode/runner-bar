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
    ///
    /// Optional because the runner agent omits this key entirely when the value
    /// is `false` (the default). Treat `nil` as `false`.
    public var disableUpdate: Bool?

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

    /// Maps Swift property names to the camelCase JSON keys written by the runner agent.
    ///
    /// The `.runner` file uses camelCase throughout — verified against real on-disk files
    /// (e.g. `"workFolder"`, `"agentId"`). PascalCase mappings will cause `keyNotFound`
    /// on every existing install.
    public enum CodingKeys: String, CodingKey {
        case workFolder           = "workFolder"
        case disableUpdate        = "disableUpdate"
        case platform             = "platform"
        case platformArchitecture = "platformArchitecture"
        case agentVersion         = "agentVersion"
        case ephemeral            = "ephemeral"
        case agentId              = "agentId"
    }

    // MARK: - Init

    /// Creates a `RunnerConfig` with the given values.
    public init(
        workFolder: String,
        disableUpdate: Bool? = nil,
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
