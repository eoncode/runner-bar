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

    /// Stable, unique identifier computed once at init-time from `agentId`
    /// when available, or a composite `runnerName + gitHubUrl` string otherwise.
    ///
    /// Storing at init (not as a computed property) ensures SwiftUI `ForEach`
    /// identity is stable across scans even if a runner is later enriched with
    /// an `agentId` it didn't have on its first discovery (e.g. LaunchAgent-only
    /// entry that gains a `.runner` JSON match on the next refresh).
    let id: String

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

    /// The launchd service label for this runner, if it is installed as a service.
    /// Format: `actions.runner.<owner>.<repo>.<name>`
    let launchLabel: String?

    // MARK: Source: ps aux

    /// `true` when a `Runner.Listener` process for this runner was found
    /// in the `ps aux` output at the last scan.
    var isRunning: Bool

    // MARK: - Init

    init(
        runnerName: String,
        gitHubUrl: String?,
        agentId: Int?,
        workFolder: String?,
        installPath: String?,
        launchLabel: String? = nil,
        isRunning: Bool
    ) {
        self.runnerName = runnerName
        self.gitHubUrl = gitHubUrl
        self.agentId = agentId
        self.workFolder = workFolder
        self.installPath = installPath
        self.launchLabel = launchLabel
        self.isRunning = isRunning
        // Compute id once at init so SwiftUI identity is stable even when
        // the model is later enriched with an agentId on a subsequent scan.
        if let aid = agentId {
            self.id = String(aid)
        } else {
            self.id = "\(runnerName)-\(gitHubUrl ?? "")"
        }
    }

    // MARK: - Display helpers

    /// Short status string used in the Settings view runner list.
    var displayStatus: String { isRunning ? "running" : "idle" }

    /// Dot colour for the status indicator: green when running, grey when idle.
    var statusColor: RunnerStatusColor { isRunning ? .running : .idle }
}

// MARK: - RunnerStatusColor

/// Semantic status colour used by the Settings view to colour the indicator dot.
enum RunnerStatusColor {
    /// Runner process is live and actively listening for jobs.
    case running
    /// Runner is installed but its process is not currently active.
    case idle
    /// Runner is registered but has been taken offline.
    /// Reserved for Phase 4 API enrichment — not produced by LocalRunnerScanner.
    case offline // Phase 4
}
