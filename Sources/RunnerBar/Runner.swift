import Foundation

/// A GitHub Actions self-hosted runner registered to a repo or organisation scope.
///
/// Decoded from the GitHub REST API response at `/repos/{owner}/{repo}/actions/runners`
/// or `/orgs/{org}/actions/runners`. After decoding, `RunnerStore.fetch()` enriches
/// each runner with local `metrics` sourced from `ps aux`.
struct Runner: Codable, Identifiable {
    /// GitHub's unique numeric ID for this runner.
    let id: Int
    /// Human-readable runner name as configured on the host machine.
    let name: String
    /// Runner connectivity status as reported by the GitHub API: `"online"` or `"offline"`.
    let status: String
    /// `true` when the runner is currently executing a job.
    /// A busy+online runner shows a yellow dot in the UI.
    let busy: Bool
    /// CPU/memory utilisation from the local `ps aux` snapshot.
    /// `nil` if no matching `Runner.Worker` process was found for this runner's slot.
    /// Populated by `RunnerStore.fetch()` after the API response is decoded \u2014
    /// not present in the JSON payload.
    var metrics: RunnerMetrics?
    /// Local installation path from .runner file or LaunchAgent plist.
    /// `nil` if discovered only via GitHub API.
    var installPath: String?
    /// GitHub URL (org or repo) where this runner is registered.
    /// Used for targeted API enrichment in Phase 4.
    var gitHubUrl: String?
    /// `true` if this runner was discovered via local scan (LaunchAgents/.runner files).
    var isLocal: Bool = false

    /// Excludes `metrics`, `installPath`, `gitHubUrl`, `isLocal` from JSON decoding \u2014 it is assigned locally after fetch,
    /// not returned by the GitHub API.
    enum CodingKeys: String, CodingKey { case id, name, status, busy }

    /// A single-line status string for display in the runner list row.
    ///
    /// Possible formats:
    /// - `"offline"` \u2014 runner is not connected
    /// - `"idle (CPU: \u2014 MEM: \u2014)"` \u2014 online but no matching process found
    /// - `"active (CPU: 12.3% MEM: 4.5%)"` \u2014 online and executing a job
    var displayStatus: String {
        if status == "offline" { return "offline" }
        let label = busy ? "active" : "idle"
        guard let runnerMetrics = metrics else { return "\(label) (CPU: \u2014 MEM: \u2014)" }
        let cpu = String(format: "%.1f", runnerMetrics.cpu)
        let mem = String(format: "%.1f", runnerMetrics.mem)
        return "\(label) (CPU: \(cpu)% MEM: \(mem)%)"
    }
}
