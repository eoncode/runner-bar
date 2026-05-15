import Foundation

// MARK: - RunnerModel

/// Represents a single locally-installed GitHub Actions self-hosted runner.
struct RunnerModel: Identifiable {
    /// Stable unique identifier derived from agentId or a composite key.
    var id: String {
        if let aid = agentId { return String(aid) }
        return "\(runnerName)-\(gitHubUrl ?? "")"
    }

    /// Display name of the runner (from `.runner` JSON or launchd label).
    var runnerName: String
    /// GitHub URL scope for this runner, e.g. `https://github.com/owner/repo`.
    var gitHubUrl: String?
    /// GitHub-assigned numeric agent ID from the `.runner` JSON file.
    var agentId: Int?
    /// Working folder path from the `.runner` JSON file.
    var workFolder: String?
    /// Path to the runner installation directory.
    var installPath: String?
    /// `true` when launchctl reports the runner service is active.
    var isRunning: Bool
    /// Live status string from the GitHub API (`"online"` / `"offline"`).
    var githubStatus: String?
    /// `true` when the GitHub API reports this runner is executing a job.
    var isBusy: Bool = false

    /// `true` when the runner is considered non-primary (hidden by default).
    var isDimmed: Bool = false
}

// MARK: - AggregateStatus

/// Summarises the overall health of all known runners for the menu bar icon.
enum AggregateStatus {
    /// All runners are offline.
    case allOffline
    /// At least one runner is online and idle.
    case someOnline
    /// At least one runner is currently executing a job.
    case busy
    /// At least one runner is in an error or unknown state.
    case error

    /// SF Symbol name used for the menu bar status icon.
    var symbolName: String {
        switch self {
        case .allOffline: return "circle"
        case .someOnline: return "circle.fill"
        case .busy:       return "circle.badge.checkmark.fill"
        case .error:      return "exclamationmark.circle.fill"
        }
    }
}
