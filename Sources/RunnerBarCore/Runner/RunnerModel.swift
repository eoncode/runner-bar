// RunnerModel.swift
// RunnerBar
//
// Locally-discovered GitHub Actions self-hosted runner, found by scanning
// LaunchAgent plists in ~/Library/LaunchAgents. Enriched with GitHub API
// data by RunnerStatusEnricher after discovery.
// See: RunnerStatusEnricher, Runner, RunnerStatus
import Foundation

// MARK: - RunnerModel

/// Represents a locally-installed GitHub Actions self-hosted runner.
///
/// Discovered by scanning LaunchAgent plists in `~/Library/LaunchAgents`.
/// After discovery, `RunnerStatusEnricher` enriches each model with live
/// GitHub API data (`githubStatus`, `isBusy`, `labels`, `runnerGroup`).
///
/// - Note: Distinct from `Runner`, which is the API-fetched remote runner snapshot.
///   `RunnerModel` is local-first; `Runner` is API-first.
/// - Note: Marked `@unchecked Sendable` because the struct carries mutable `var`
///   properties that prevent the compiler from synthesising `Sendable` conformance
///   automatically. All mutations occur on `@MainActor` in practice (via
///   `LocalRunnerStore` and `RunnerStatusEnricher`), making this safe.
///   TODO: Remove `@unchecked` once all mutable properties are actor-isolated or `let`.
/// - SeeAlso: `Runner`, `RunnerStatus`, `RunnerStatusEnricher`, `LocalRunnerStore`
public struct RunnerModel: @unchecked Sendable, Identifiable, Equatable {
    // MARK: Stored Properties

    /// String-based ID so `LocalRunnerScanner` can use `runnerName` as the dedup key.
    public let id: String
    /// The human-readable name of the runner as configured on the host machine.
    public let runnerName: String
    /// Absolute path to the runner agent installation directory on disk.
    public let installPath: String?
    /// The GitHub URL scope this runner is registered to (repo or org URL).
    ///
    /// `var` because `LocalRunnerScanner` may patch this after initial init
    /// when the `.runner` config file is read separately from the LaunchAgent plist.
    public var gitHubUrl: String?
    /// GitHub's internal numeric agent ID for this runner.
    public let agentId: Int?
    /// Absolute path to the runner's `_work` folder on disk.
    public let workFolder: String?
    /// Labels registered for this runner (e.g. `["self-hosted", "macOS", "arm64"]`).
    public let labels: [String]

    // MARK: - Fields from .runner JSON (#491)

    /// Operating system string from `.runner` JSON `platform` key (e.g. `"linux"`, `"osx"`).
    public let platform: String?
    /// Architecture from `.runner` JSON `platformArchitecture` key (e.g. `"X64"`, `"ARM64"`).
    public let platformArchitecture: String?
    /// Agent version string from `.runner` JSON `agentVersion` key (e.g. `"2.320.0"`).
    public let agentVersion: String?
    /// Whether the runner was registered as ephemeral from `.runner` JSON `ephemeral` key.
    public let isEphemeral: Bool
    /// GitHub runner group name. Populated by `RunnerStatusEnricher` via the GitHub API.
    public var runnerGroup: String?

    /// Launchctl / process running state.
    ///
    /// `var` so optimistic UI updates and the Source-3 live-service check can
    /// both mutate it in-place on the array.
    public var isRunning: Bool

    /// GitHub API-reported connectivity status. Set by `RunnerStatusEnricher`.
    ///
    /// `nil` when the runner has not yet been enriched or the API call failed.
    public var githubStatus: RunnerStatus?

    /// Whether the runner is currently executing a job. Set by `RunnerStatusEnricher`.
    public var isBusy: Bool

    /// Short error string surfaced directly in the runner row after a failed lifecycle action.
    ///
    /// When non-nil, `displayStatus` shows this string instead of the normal status
    /// so the user sees the problem directly in the row.
    /// Cleared automatically the next time `refresh()` replaces the runner array.
    public var lifecycleWarning: String?

    /// CPU/memory utilisation from the local `ps aux` snapshot, matched by `installPath`.
    ///
    /// `nil` if no matching process was found for this runner, or the runner is not busy.
    /// Populated by `LocalRunnerStore.refresh()` after scanning.
    public var metrics: RunnerMetrics?

    // MARK: - Init

    /// Creates a new `RunnerModel` instance.
    ///
    /// - Parameters:
    ///   - id: Stable dedup key. Defaults to `runnerName` when omitted.
    ///   - runnerName: Human-readable runner name.
    ///   - gitHubUrl: GitHub scope URL (repo or org). May be patched post-init.
    ///   - agentId: GitHub internal numeric agent ID.
    ///   - workFolder: Absolute path to the runner `_work` folder.
    ///   - installPath: Absolute path to the runner installation directory.
    ///   - isRunning: Whether the runner agent process is currently running.
    ///   - labels: Registered runner labels.
    ///   - githubStatus: GitHub API connectivity status. `nil` until enriched.
    ///   - isBusy: Whether the runner is executing a job.
    ///   - lifecycleWarning: Optional error string shown in the runner row.
    ///   - platform: OS platform string from `.runner` JSON.
    ///   - platformArchitecture: Architecture string from `.runner` JSON.
    ///   - agentVersion: Agent version string from `.runner` JSON.
    ///   - isEphemeral: Whether the runner is registered as ephemeral.
    ///   - runnerGroup: Runner group name from the GitHub API.
    ///   - metrics: Optional CPU/memory snapshot from `ps aux`.
    public init(
        id: String? = nil,
        runnerName: String,
        gitHubUrl: String?,
        agentId: Int?,
        workFolder: String?,
        installPath: String?,
        isRunning: Bool,
        labels: [String] = [],
        githubStatus: RunnerStatus? = nil,
        isBusy: Bool = false,
        lifecycleWarning: String? = nil,
        platform: String? = nil,
        platformArchitecture: String? = nil,
        agentVersion: String? = nil,
        isEphemeral: Bool = false,
        runnerGroup: String? = nil,
        metrics: RunnerMetrics? = nil
    ) {
        self.id = id ?? runnerName
        self.runnerName = runnerName
        self.gitHubUrl = gitHubUrl
        self.agentId = agentId
        self.workFolder = workFolder
        self.installPath = installPath
        self.isRunning = isRunning
        self.labels = labels
        self.githubStatus = githubStatus
        self.isBusy = isBusy
        self.lifecycleWarning = lifecycleWarning
        self.platform = platform
        self.platformArchitecture = platformArchitecture
        self.agentVersion = agentVersion
        self.isEphemeral = isEphemeral
        self.runnerGroup = runnerGroup
        self.metrics = metrics
    }

    // MARK: - Private state resolution

    /// Unified display state resolved from all contributing fields.
    ///
    /// Single source of truth consumed by both `displayStatus` and `statusColor`,
    /// eliminating the need to keep two independent conditional trees in sync.
    ///
    /// - Note: Evaluated in priority order: lifecycle warning → local running
    ///   state → GitHub API status.
    /// - Note: `.running` and `.githubOnline` are deliberately distinct cases:
    ///   `.running` means the local agent process is up (green dot);
    ///   `.githubOnline` means the process is *not* running locally but GitHub
    ///   still reports it as reachable (yellow dot). Collapsing these two cases
    ///   would silently break dot-colour semantics.
    private var resolvedState: ResolvedState {
        if lifecycleWarning != nil { return .warning }
        if isRunning { return (isBusy || githubStatus == .busy) ? .busy : .running }
        switch githubStatus {
        case .online:  return .githubOnline
        case .busy:    return .busy
        default:       return .offline
        }
    }

    /// The possible display states used internally by `displayStatus` and `statusColor`.
    private enum ResolvedState {
        /// A lifecycle action failed; `lifecycleWarning` holds the error string.
        case warning
        /// Runner is local-process-running and executing a job.
        case busy
        /// Runner is local-process-running but not executing a job.
        case running
        /// Runner is not running locally but the GitHub API reports it as online.
        ///
        /// Distinct from `.running`: the local agent process is absent, so the
        /// dot colour is yellow (idle) rather than green (active process).
        case githubOnline
        /// Runner is offline from GitHub's perspective and not running locally.
        case offline
    }

    // MARK: - Derived display

    /// Human-readable status label shown in the settings runner row.
    ///
    /// When a lifecycle warning is set it takes priority over the normal status.
    /// - `"busy"` — runner is running and executing a job (#773).
    /// - `"running"` — runner process is up but not executing a job.
    /// - `"online"` — runner is not running locally but GitHub reports it online.
    /// - `"offline"` — runner is not reachable.
    public var displayStatus: String {
        switch resolvedState {
        case .warning:     return lifecycleWarning!  // resolvedState only reaches .warning when lifecycleWarning != nil
        case .busy:        return "busy"
        case .running:     return "running"
        case .githubOnline: return "online"
        case .offline:     return "offline"
        }
    }

    /// Dot colour category used by `SettingsView.localRunnerDotColor(for:)`.
    public var statusColor: StatusColor {
        switch resolvedState {
        case .warning:     return .offline
        case .busy:        return .busy
        case .running:     return .running
        case .githubOnline: return .idle
        case .offline:     return .offline
        }
    }

    /// Dot colour categories for the runner status indicator.
    public enum StatusColor {
        /// Runner process is up and not busy.
        case running
        /// Runner is executing a job.
        case busy
        /// Runner is not running locally but online per GitHub.
        case idle
        /// Runner is offline or a lifecycle error occurred.
        case offline
    }
}
