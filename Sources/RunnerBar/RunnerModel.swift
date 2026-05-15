import Foundation
import SwiftUI

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
    /// Labels configured for this runner (from `.runner` JSON `customLabels`).
    var labels: [String] = []

    /// `true` when the runner is considered non-primary (hidden by default).
    var isDimmed: Bool = false

    // MARK: - Derived display helpers

    /// Semantic colour state for the status dot in `SettingsView`.
    enum StatusColor {
        case running
        case busy
        case idle
        case offline
    }

    /// Colour state derived from `isRunning`, `githubStatus`, and `isBusy`.
    var statusColor: StatusColor {
        guard isRunning else { return .offline }
        guard githubStatus == "online" else { return .idle }
        return isBusy ? .busy : .running
    }

    /// Single-line status string displayed in the local runners row.
    var displayStatus: String {
        guard isRunning else { return "offline" }
        guard let apiStatus = githubStatus else { return "running" }
        if apiStatus == "offline" { return "offline" }
        return isBusy ? "active" : "idle"
    }
}

// NOTE: AggregateStatus is defined in RunnerStore.swift — do not redeclare here.
