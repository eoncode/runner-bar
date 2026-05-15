import Foundation
import Combine
import SwiftUI

// MARK: - GitHub API compatibility shims
// Bridges call-sites that still use the pre-refactor free-function API
// to the new shell()-based helpers in GitHub.swift.

/// Calls the GitHub API via `gh api` and returns the raw JSON data, or nil on error.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    let output = shell("/opt/homebrew/bin/gh api \(endpoint)", timeout: timeout)
    guard !output.isEmpty, !output.lowercased().hasPrefix("error") else { return nil }
    return output.data(using: .utf8)
}

/// Calls the GitHub API via `gh api --method POST` and returns true on success.
@discardableResult
func ghPost(_ endpoint: String, timeout: TimeInterval = 30) -> Bool {
    let output = shell("/opt/homebrew/bin/gh api --method POST \(endpoint)", timeout: timeout)
    return output.isEmpty || !output.lowercased().contains("error")
}

/// Returns the path to the `gh` CLI binary, or nil if not found.
func ghBinaryPath() -> String? {
    let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Global flag set by RunnerStore when the GitHub API rate-limit is hit.
var ghIsRateLimited = false

/// Extracts "owner/repo" from a GitHub HTML URL such as
/// https://github.com/owner/repo/actions/runs/123/jobs/456
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.host == "github.com" else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2 else { return nil }
    return "\(parts[0])/\(parts[1])"
}

/// Extracts the numeric run ID from a GitHub Actions HTML URL.
func runIDFromHtmlUrl(_ urlString: String?) -> Int? {
    guard let urlString else { return nil }
    let parts = urlString.components(separatedBy: "/")
    for (i, part) in parts.enumerated() where part == "runs" && i + 1 < parts.count {
        return Int(parts[i + 1])
    }
    return nil
}

/// Fetches active (queued / in_progress) jobs for a scope using the GitHub API.
func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    guard let data = ghAPI("repos/\(scope)/actions/runs?status=in_progress&per_page=100") else { return [] }
    struct RunsEnvelope: Decodable {
        let workflowRuns: [WorkflowRun]
        enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
    }
    let runs = (try? JSONDecoder().decode(RunsEnvelope.self, from: data))?.workflowRuns ?? []
    var jobs: [ActiveJob] = []
    for run in runs {
        guard let jobsData = ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=100") else { continue }
        let jobList = (try? JSONDecoder().decode(WorkflowJobsResponse.self, from: jobsData))?.jobs ?? []
        for job in jobList where job.status == "in_progress" || job.status == "queued" {
            jobs.append(ActiveJob(workflowJob: job, scope: scope))
        }
    }
    return jobs
}

/// Fetches self-hosted runners for a scope via the GitHub API.
func fetchRunners(for scope: String) -> [Runner] {
    let parts = scope.split(separator: "/")
    let endpoint: String
    if parts.count == 1 {
        endpoint = "orgs/\(scope)/actions/runners"
    } else {
        endpoint = "repos/\(scope)/actions/runners"
    }
    guard let data = ghAPI(endpoint) else { return [] }
    struct RunnersEnvelope: Decodable {
        let runners: [Runner]
    }
    return (try? JSONDecoder().decode(RunnersEnvelope.self, from: data))?.runners ?? []
}

/// Fetches the log text for a single step using `gh run view`.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard let ghPath = ghBinaryPath() else { return nil }
    let output = shell("\(ghPath) api repos/\(scope)/actions/jobs/\(jobID)/logs", timeout: 30)
    guard !output.isEmpty else { return nil }
    return output
}

// MARK: - SystemStats compatibility shims
// The views were written against a `SystemStats` struct + `SystemStatsViewModel`
// ObservableObject. The new SystemStats.swift renamed these to
// SystemStatsSnapshot + SystemStatsPoller. These shims restore the old API.

/// Legacy struct alias — maps to the new SystemStatsSnapshot.
typealias SystemStats = SystemStatsSnapshot

extension SystemStatsSnapshot {
    /// CPU usage percentage (0–100).
    var cpuUsage: Double { cpuPercent }
    /// Memory usage percentage (0–100).
    var memUsage: Double { memPercent }
    /// Disk used percentage — approximated via `df /`.
    var diskUsedPct: Double { SystemStatsViewModel.lastDiskUsedPct }
    /// Disk free percentage.
    var diskFreePct: Double { max(0, 100 - diskUsedPct) }
}

/// ObservableObject wrapper that the popover views depend on.
final class SystemStatsViewModel: ObservableObject {
    @Published var stats: SystemStatsSnapshot = SystemStatsSnapshot(cpuPercent: 0, memPercent: 0)
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var memHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var diskHistory: [Double] = Array(repeating: 0, count: 30)

    /// Cached last disk-used pct so the extension property can read it.
    static var lastDiskUsedPct: Double = 0

    private var observerToken: Int?

    func start() {
        SystemStatsPoller.shared.start()
        observerToken = SystemStatsPoller.shared.addObserver { [weak self] snapshot in
            guard let self else { return }
            let disk = Self.fetchDiskUsedPct()
            Self.lastDiskUsedPct = disk
            self.stats = snapshot
            self.cpuHistory = Array((self.cpuHistory + [snapshot.cpuPercent]).suffix(30))
            self.memHistory = Array((self.memHistory + [snapshot.memPercent]).suffix(30))
            self.diskHistory = Array((self.diskHistory + [disk]).suffix(30))
        }
    }

    func stop() {
        // SystemStatsPoller runs indefinitely; nothing to stop.
    }

    // MARK: - Disk usage

    private static func fetchDiskUsedPct() -> Double {
        let output = shell("df / | tail -1", timeout: 3)
        let cols = output.split(separator: " ").map(String.init)
        // df columns: Filesystem 512-Blk-Used Available Capacity ...
        // Capacity column contains e.g. "42%"
        if let cap = cols.first(where: { $0.hasSuffix("%") }),
           let val = Double(cap.dropLast()) {
            return val
        }
        // Fallback: use 1K-blocks columns (col index 2=used, 3=avail)
        if cols.count >= 4,
           let used = Double(cols[2]),
           let avail = Double(cols[3]),
           used + avail > 0 {
            return (used / (used + avail)) * 100
        }
        return 0
    }
}
