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
    /// Populated by `RunnerStore.fetch()` after the API response is decoded —
    /// not present in the JSON payload.
    var metrics: RunnerMetrics?

    /// Excludes `metrics` from JSON decoding — it is assigned locally after fetch,
    /// not returned by the GitHub API.
    enum CodingKeys: String, CodingKey {
        case id, name, status, busy
    }

    /// A single-line status string for display in the runner list row.
    ///
    /// Possible formats:
    /// - `"offline"` — runner is not connected
    /// - `"idle (CPU: — MEM: —)"` — online but no matching process found
    /// - `"active (CPU: 12.3% MEM: 4.5%)"` — online and executing a job
    var displayStatus: String {
        if status == "offline" { return "offline" }
        let label = busy ? "active" : "idle"
        guard let m = metrics else {
            return "\(label) (CPU: — MEM: —)"
        }
        let cpu = String(format: "%.1f", m.cpu)
        let mem = String(format: "%.1f", m.mem)
        return "\(label) (CPU: \(cpu)% MEM: \(mem)%)"
    }
}
