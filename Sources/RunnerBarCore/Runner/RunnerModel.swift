// RunnerModel.swift
// RunnerBar
// swiftlint:disable type_body_length
import Foundation

// MARK: - RunnerModel

/// Represents a locally-installed GitHub Actions self-hosted runner.
/// Discovered by scanning LaunchAgent plists in ~/Library/LaunchAgents.
public struct RunnerModel: Identifiable, Equatable {
    // MARK: Stored

    /// String-based ID so LocalRunnerScanner can use runnerName as the dedup key.
    public let id: String
    /// The runnerName constant.
    public let runnerName: String
    /// The installPath constant.
    public let installPath: String?
    /// The gitHubUrl property.
    public var gitHubUrl: String?   // var — LocalRunnerScanner may patch this after init
    /// The agentId constant.
    public let agentId: Int?
    /// The workFolder constant.
    public let workFolder: String?
    /// The labels constant.
    public let labels: [String]

    // MARK: - Fields from .runner JSON (#491)

    /// Operating system string from `.runner` JSON `platform` key (e.g. "linux", "osx").
    public let platform: String?
    /// Architecture from `.runner` JSON `platformArchitecture` key (e.g. "X64", "ARM64").
    public let platformArchitecture: String?
    /// Agent version string from `.runner` JSON `agentVersion` key (e.g. "2.320.0").
    public let agentVersion: String?
    /// Whether the runner was registered as ephemeral from `.runner` JSON `ephemeral` key.
    public let isEphemeral: Bool
    /// GitHub runner group name. Populated by RunnerStatusEnricher via the GitHub API.
    public var runnerGroup: String?

    /// Launchctl / process running state. `var` so optimistic UI updates and
    /// the Source-3 live-service check can both mutate it in-place on the array.
    public var isRunning: Bool

    /// GitHub API-reported status. `var` — set by RunnerStatusEnricher.
    public var githubStatus: String?   // "online" | "offline" | "busy" | nil

    /// GitHub API busy flag. `var` — set by RunnerStatusEnricher.
    public var isBusy: Bool

    /// Set by SettingsView after a failed lifecycle action (start/stop).
    /// When non-nil, `displayStatus` surfaces this string instead of the
    /// normal status so the user sees the problem directly in the row.
    /// Cleared automatically the next time refresh() replaces the runner array.
    public var lifecycleWarning: String?

    /// CPU/memory utilisation from the local `ps aux` snapshot, matched by installPath.
    /// `nil` if no matching process was found for this runner, or the runner is not busy.
    /// Populated by `LocalRunnerStore.refresh()` after scanning.
    public var metrics: RunnerMetrics?

    // MARK: - Init

    // swiftlint:disable:next function_parameter_count
    /// Creates a new instance.
    public init(
        id: String? = nil,
        runnerName: String,
        gitHubUrl: String?,
        agentId: Int?,
        workFolder: String?,
        installPath: String?,
        isRunning: Bool,
        labels: [String] = [],
        githubStatus: String? = nil,
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

    // MARK: - Derived display

    /// Human-readable status label shown in the settings runner row.
    /// When a lifecycle warning is set it takes priority over the normal status.
    public var displayStatus: String {
        if let warning = lifecycleWarning { return warning }
        if isRunning {
            if isBusy || githubStatus == "busy" { return "running" }
            return "running"
        } else {
            switch githubStatus {
            case "online": return "online"
            case "busy":   return "busy"
            default:       return "offline"
            }
        }
    }

    /// Enumerates possible values for StatusColor.
    public enum StatusColor {
        /// The `running` case.
        case running, busy, idle, offline
    }

    /// Dot color category used by `SettingsView.localRunnerDotColor(for:)`.
    public var statusColor: StatusColor {
        if lifecycleWarning != nil { return .offline }
        if isRunning {
            if isBusy || githubStatus == "busy" { return .busy }
            return .running
        } else {
            if githubStatus == "online" || githubStatus == "busy" { return .idle }
            return .offline
        }
    }
}
// swiftlint:enable type_body_length
