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
    // MARK: - Config

    /// Bundles all construction parameters for `RunnerModel` into a single value,
    /// keeping the primary `init` under the S107 7-parameter limit.
    struct Config {
        let runnerName: String
        let gitHubUrl: String?
        let agentId: Int?
        let workFolder: String?
        let labels: [String]
        let installPath: String?
        let isRunning: Bool
        let githubStatus: String?
        let isBusy: Bool

        // NOSONAR S107 — Config.init intentionally mirrors all RunnerModel fields;
        // splitting further would add boilerplate with no architectural benefit.
        // This struct exists solely to keep RunnerModel.init under the S107 limit.
        init(
            runnerName: String,
            gitHubUrl: String?,
            agentId: Int?,
            workFolder: String?,
            labels: [String] = [],
            installPath: String?,
            isRunning: Bool,
            githubStatus: String? = nil,
            isBusy: Bool = false
        ) {
            self.runnerName = runnerName
            self.gitHubUrl = gitHubUrl
            self.agentId = agentId
            self.workFolder = workFolder
            self.labels = labels
            self.installPath = installPath
            self.isRunning = isRunning
            self.githubStatus = githubStatus
            self.isBusy = isBusy
        }
    }

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
    /// Read from `workFolder` in `.runner`. Mutable so Phase 2 config edits
    /// are reflected without requiring a full re-scan.
    var workFolder: String?

    /// Custom labels attached to this runner (e.g. `["macOS", "self-hosted"]`).
    /// Populated from `customLabels` in `.runner` JSON when present.
    /// Mutable so Phase 2 config edits are reflected immediately.
    var labels: [String]

    // MARK: Source: file system

    /// Absolute path to the directory that contains the runner installation
    /// (the parent of the `.runner` JSON file, or the LaunchAgent install path).
    let installPath: String?

    // MARK: Source: launchctl

    /// `true` when a launchd service with this runner's label was found in
    /// `launchctl list` output at the last scan, indicating the runner is
    /// actively registered and running. Determined by `LocalRunnerScanner`
    /// using `launchctl list | grep actions.runner`.
    var isRunning: Bool

    // MARK: Source: Phase 4 — GitHub API enrichment

    /// Live status reported by the GitHub API: `"online"`, `"offline"`, or `nil`
    /// when enrichment hasn't run yet. Set by `RunnerStatusEnricher` in Phase 4.
    var githubStatus: String?

    /// `true` when the GitHub API reports this runner is currently executing a job.
    /// Set by `RunnerStatusEnricher` in Phase 4. `false` by default (not enriched).
    var isBusy: Bool

    // MARK: - Init

    /// Primary init — accepts a `Config` to stay under the S107 parameter limit.
    init(config: Config) {
        runnerName   = config.runnerName
        gitHubUrl    = config.gitHubUrl
        agentId      = config.agentId
        workFolder   = config.workFolder
        labels       = config.labels
        installPath  = config.installPath
        isRunning    = config.isRunning
        githubStatus = config.githubStatus
        isBusy       = config.isBusy
        if let aid = config.agentId {
            id = String(aid)
        } else {
            id = "\(config.runnerName)-\(config.gitHubUrl ?? "")"
        }
    }

    /// Convenience factory that preserves the original call-site signature so
    /// existing callers (`LocalRunnerScanner`, `RunnerStatusEnricher`) require
    /// no changes.
    static func make(
        runnerName: String,
        gitHubUrl: String?,
        agentId: Int?,
        workFolder: String?,
        labels: [String] = [],
        installPath: String?,
        isRunning: Bool,
        githubStatus: String? = nil,
        isBusy: Bool = false
    ) -> RunnerModel {
        RunnerModel(config: Config(
            runnerName: runnerName,
            gitHubUrl: gitHubUrl,
            agentId: agentId,
            workFolder: workFolder,
            labels: labels,
            installPath: installPath,
            isRunning: isRunning,
            githubStatus: githubStatus,
            isBusy: isBusy
        ))
    }

    // MARK: - Display helpers

    /// Short status string used in the Settings view runner list.
    /// Prefers the GitHub-enriched status when available (Phase 4), falling
    /// back to the local launchctl state otherwise.
    var displayStatus: String {
        if let ghStatus = githubStatus {
            if isBusy { return "busy" }
            return ghStatus
        }
        return isRunning ? "running" : "idle"
    }

    /// Dot colour for the status indicator.
    /// - `.running` (green): launchctl shows live, or GitHub reports online+idle
    /// - `.busy` (yellow): GitHub reports the runner is executing a job
    /// - `.idle` (grey): installed but not currently active
    /// - `.offline` (red): GitHub reports offline, or runner registered but down
    var statusColor: RunnerStatusColor {
        if let ghStatus = githubStatus {
            if ghStatus == "offline" { return .offline }
            return isBusy ? .busy : .running
        }
        return isRunning ? .running : .idle
    }
}

// MARK: - RunnerStatusColor

/// Semantic status colour used by the Settings view to colour the indicator dot.
enum RunnerStatusColor {
    /// Runner process is live and actively listening for jobs.
    case running
    /// Runner is installed but its process is not currently active.
    case idle
    /// Runner is currently executing a job (GitHub API enrichment — Phase 4).
    case busy
    /// Runner is registered but has been taken offline.
    /// Reserved for Phase 4 API enrichment — not produced by LocalRunnerScanner.
    case offline
}
