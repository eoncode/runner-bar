import Foundation

// MARK: - RunnerModel

/// Represents a locally-installed GitHub Actions self-hosted runner discovered
/// via file-system scanning. This is distinct from `Runner` (which is decoded
/// from the GitHub REST API). The two models are intentionally separate so that
/// local discovery (Phase 1) works without any network call.
///
/// Fields are populated by `LocalRunnerScanner` and can later be enriched with
/// live GitHub API status in Phase 4.
struct RunnerModel: Identifiable, Hashable {
    // MARK: Identity

    /// Stable, unique identifier derived from `agentId` when available, or a
    /// hash of `runnerName + gitHubUrl` otherwise.
    var id: String {
        if let aid = agentId { return String(aid) }
        return "\(runnerName)-\(gitHubUrl ?? "")"
    }

    /// Human-readable runner name (`runnerName` field in `.runner` JSON, or
    /// parsed from the LaunchAgent plist filename).
    let runnerName: String

    // MARK: Source: .runner JSON

    /// The GitHub URL the runner is registered to, e.g.
    /// `https://github.com/owner/repo` or `https://github.com/myorg`.
    /// Read from the `gitHubUrl` field in `.runner`.
    let gitHubUrl: String?

    /// GitHub's numeric agent identifier for this runner installation.
    /// Read from the `agentId` field in `.runner`. Used as the primary
    /// deduplication key across scan sources.
    let agentId: Int?

    /// The working directory for runner jobs, as configured during setup.
    /// Read from `workFolder` in `.runner`.
    let workFolder: String?

    // MARK: Source: file system

    /// Absolute path to the directory that contains the runner installation
    /// (the parent of the `.runner` JSON file, or the LaunchAgent install path).
    let installPath: String?

    // MARK: Source: ps aux

    /// `true` when a `Runner.Listener` process for this runner was found
    /// in the `ps aux` output at the last scan.
    var isRunning: Bool

    // MARK: - Display helpers

    /// Short status string used in the Settings view runner list.
    var displayStatus: String { isRunning ? "running" : "idle" }

    /// Dot colour for the status indicator: green when running, grey when idle.
    var statusColor: RunnerStatusColor { isRunning ? .running : .idle }
}

// MARK: - RunnerStatusColor

/// Semantic status colour used by the Settings view to colour the indicator dot.
enum RunnerStatusColor {
    case running
    case idle
    case offline
}
