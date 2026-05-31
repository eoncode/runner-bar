// Runner.swift
// RunnerBar
//
// API-decoded snapshot of a single GitHub Actions self-hosted runner.
// Populated by the GitHub REST API; enriched locally with RunnerMetrics after fetch.
// See: RunnerModel, RunnerStatus, RunnerMetrics
import Foundation

// MARK: - Runner

/// A GitHub Actions self-hosted runner registered to a repo or organisation scope.
///
/// Decoded from the GitHub REST API response at `/repos/{owner}/{repo}/actions/runners`
/// or `/orgs/{org}/actions/runners`. After decoding, `RunnerStore.fetch()` enriches
/// each runner with local `metrics` sourced from `ps aux`.
///
/// - Note: This type represents the **API-fetched** remote runner list. For locally
///   installed runners discovered via LaunchAgent plists, see `RunnerModel`.
/// - SeeAlso: `RunnerModel`, `RunnerStatus`, `RunnerMetrics`
public struct Runner: Codable, Identifiable {
    /// GitHub's unique numeric ID for this runner.
    public let id: Int
    /// Human-readable runner name as configured on the host machine.
    public let name: String
    /// Runner connectivity status as reported by the GitHub API.
    public let status: RunnerStatus
    /// `true` when the runner is currently executing a job.
    /// A busy+online runner shows a yellow dot in the UI.
    public let busy: Bool
    /// CPU/memory utilisation from the local `ps aux` snapshot.
    ///
    /// `nil` if no matching `Runner.Worker` process was found for this runner's slot.
    /// Populated by `RunnerStore.fetch()` after the API response is decoded —
    /// not present in the JSON payload.
    public var metrics: RunnerMetrics?

    /// Creates a new `Runner` instance.
    ///
    /// - Parameters:
    ///   - id: GitHub's unique numeric runner ID.
    ///   - name: Human-readable runner name.
    ///   - status: Connectivity status from the GitHub API.
    ///   - busy: `true` when the runner is executing a job.
    ///   - metrics: Optional local CPU/memory snapshot. Defaults to `nil`.
    public init(id: Int, name: String, status: RunnerStatus, busy: Bool, metrics: RunnerMetrics? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.busy = busy
        self.metrics = metrics
    }

    /// Excludes `metrics` from JSON decoding — it is assigned locally after fetch,
    /// not returned by the GitHub API.
    private enum CodingKeys: String, CodingKey {
        /// Maps to the `id` JSON field.
        case id
        /// Maps to the `name` JSON field.
        case name
        /// Maps to the `status` JSON field.
        case status
        /// Maps to the `busy` JSON field.
        case busy
    }

    /// A single-line status string for display in the runner list row.
    ///
    /// Returns `"offline"` for both `.offline` and any `.unknown` status value,
    /// since an unrecognised API status should not be displayed as idle or active.
    ///
    /// Possible formats:
    /// - `"offline"` — runner is not connected or status is unrecognised
    /// - `"idle (CPU: — MEM: —)"` — online but no matching process found
    /// - `"active (CPU: 12.3% MEM: 4.5%)"` — online and executing a job
    public var displayStatus: String {
        switch status {
        case .offline, .unknown: return "offline"
        default: break
        }
        let label = busy ? "active" : "idle"
        guard let m = metrics else { return "\(label) (CPU: \u{2014} MEM: \u{2014})" }
        let cpu = String(format: "%.1f", m.cpu)
        let mem = String(format: "%.1f", m.mem)
        return "\(label) (CPU: \(cpu)% MEM: \(mem)%)"
    }
}
