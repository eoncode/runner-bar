import Foundation

// MARK: - Runner
/// Represents a single GitHub Actions self-hosted runner as returned by the GitHub API.
struct Runner: Identifiable, Codable, Hashable {
    /// GitHub-assigned numeric runner ID.
    let id: Int
    /// Human-readable runner name (hostname or configured label).
    let name: String
    /// Current OS reported by the runner agent.
    let os: String?
    /// Runner status as reported by the GitHub API (e.g. `"online"`, `"offline"`).
    let status: String
    /// Whether this runner is currently executing a job.
    let busy: Bool
    /// Labels assigned to this runner (used for job routing).
    let labels: [RunnerLabel]
    /// Latest CPU/memory metrics snapshot, if available.
    var metrics: RunnerMetricsSnapshot?

    /// `true` if this runner was registered on the local machine via `LocalRunnerScanner`.
    var isLocal: Bool { labels.contains { $0.name == "self-hosted" } }
}

// MARK: - RunnerLabel
/// A single label attached to a runner.
struct RunnerLabel: Codable, Hashable {
    /// The label string (e.g. `"self-hosted"`, `"macOS"`, `"X64"`).
    let name: String
}

// MARK: - RunnerMetricsSnapshot
/// Lightweight CPU/MEM snapshot polled by `RunnerMetrics`.
struct RunnerMetricsSnapshot: Codable, Hashable {
    /// CPU utilisation percentage (0–100).
    let cpu: Double
    /// Memory utilisation percentage (0–100).
    let mem: Double
}
