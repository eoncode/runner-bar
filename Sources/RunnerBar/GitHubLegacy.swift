import Foundation

// MARK: - GitHub legacy compatibility shims
//
// GitHub.swift was refactored to use typed fetchWorkflowRuns/fetchJobs/etc.
// These shims restore the old free-function API so existing call sites compile
// unchanged while the full migration is completed incrementally.
//
// ⚠️ DO NOT add new call sites against these shims — use the typed API instead.
// Each shim is marked with the file(s) that still depend on it.

// MARK: - gh binary path

/// Returns the path to the `gh` CLI binary, searching common Homebrew locations.
/// Depended on by: LogFetcher.swift
func ghBinaryPath() -> String? {
    let candidates = [
        "/opt/homebrew/bin/gh",   // Apple Silicon Homebrew
        "/usr/local/bin/gh",      // Intel Homebrew
        "/usr/bin/gh"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// MARK: - Rate-limit flag

/// Global flag set to `true` by the poller when a 403/rate-limit response is
/// detected, and cleared at the start of each poll cycle.
/// Depended on by: RunnerStore.swift
var ghIsRateLimited = false

// MARK: - Generic REST helpers

/// Calls `gh api <endpoint>` and returns the raw response bytes, or `nil` on
/// error / empty output.
/// Depended on by: ActionGroup.swift, AppDelegate.swift, RunnerStatusEnricher.swift,
///                 RunnerStoreState.swift
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard let ghPath = ghBinaryPath() else { return nil }
    let output = shell("\(ghPath) api \(endpoint)", timeout: timeout)
    guard !output.isEmpty else { return nil }
    // Treat a 403 as a rate-limit signal.
    if output.contains("\"message\":") && output.contains("API rate limit") {
        ghIsRateLimited = true
        return nil
    }
    return output.data(using: .utf8)
}

/// Calls `gh api --method POST <endpoint>` and returns `true` on apparent success.
/// Depended on by: ActionDetailView.swift, JobDetailView.swift
@discardableResult
func ghPost(_ endpoint: String, timeout: TimeInterval = 30) -> Bool {
    guard let ghPath = ghBinaryPath() else { return false }
    let output = shell("\(ghPath) api --method POST \(endpoint)", timeout: timeout)
    return !output.lowercased().contains("error") && !output.lowercased().contains("failed")
}

// MARK: - URL-parsing helpers

/// Extracts `owner/repo` from a GitHub HTML URL string.
/// e.g. `https://github.com/owner/repo/actions/runs/123` → `"owner/repo"`
/// Depended on by: AppDelegate.swift, JobDetailView.swift, RunnerStoreState.swift
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard
        let s = urlString,
        let url = URL(string: s),
        url.host == "github.com",
        url.pathComponents.count >= 3
    else { return nil }
    let parts = url.pathComponents  // ["/", "owner", "repo", ...]
    return "\(parts[1])/\(parts[2])"
}

/// Extracts the numeric run ID from a GitHub Actions HTML URL.
/// e.g. `.../actions/runs/9876543/jobs/...` → `9876543`
/// Depended on by: JobDetailView.swift
func runIDFromHtmlUrl(_ urlString: String?) -> Int? {
    guard let s = urlString else { return nil }
    let parts = s.components(separatedBy: "/")
    for (i, part) in parts.enumerated() where part == "runs" && i + 1 < parts.count {
        return Int(parts[i + 1])
    }
    return nil
}

// MARK: - High-level fetchers

/// Fetches in-progress and recently queued jobs for a repo scope.
/// Depended on by: RunnerStoreState.swift
func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    let endpoint = "repos/\(scope)/actions/runs?status=in_progress&per_page=50"
    guard let data = ghAPI(endpoint) else { return [] }
    struct RunsEnvelope: Decodable {
        struct Run: Decodable {
            let id: Int
            enum CodingKeys: String, CodingKey { case id }
        }
        let workflowRuns: [Run]
        enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
    }
    guard let envelope = try? JSONDecoder().decode(RunsEnvelope.self, from: data) else { return [] }
    var jobs: [ActiveJob] = []
    for run in envelope.workflowRuns {
        let jobEndpoint = "repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=100"
        guard let jobData = ghAPI(jobEndpoint) else { continue }
        let decoded = (try? JSONDecoder().decode(WorkflowJobsResponse.self, from: jobData))?.jobs ?? []
        let activeJobs = decoded.compactMap { ActiveJob(workflowJob: $0, scope: scope) }
        jobs.append(contentsOf: activeJobs)
    }
    return jobs
}

/// Fetches self-hosted runners registered for a repo or org scope.
/// Depended on by: RunnerStore.swift
func fetchRunners(for scope: String) -> [Runner] {
    // Try repo-level first; fall back to org-level.
    let repoEndpoint = "repos/\(scope)/actions/runners?per_page=100"
    if let data = ghAPI(repoEndpoint),
       let runners = decodeRunners(from: data, scope: scope), !runners.isEmpty {
        return runners
    }
    // Org-level: scope may be just an org name (no slash) or we take the owner part.
    let org = scope.contains("/") ? String(scope.split(separator: "/").first ?? Substring(scope)) : scope
    let orgEndpoint = "orgs/\(org)/actions/runners?per_page=100"
    guard let data = ghAPI(orgEndpoint),
          let runners = decodeRunners(from: data, scope: scope) else { return [] }
    return runners
}

/// Fetches the log text for a specific step inside a job.
/// Depended on by: StepLogView.swift
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard let ghPath = ghBinaryPath() else { return nil }
    // Download the zip archive of logs, then extract the step file.
    let tmpDir = NSTemporaryDirectory() + "runnerbar_logs_\(jobID)"
    let zipPath = tmpDir + ".zip"
    // Clean up any previous attempt.
    try? FileManager.default.removeItem(atPath: zipPath)
    try? FileManager.default.removeItem(atPath: tmpDir)
    let endpoint = "repos/\(scope)/actions/jobs/\(jobID)/logs"
    // gh api with --header to follow redirect gives us the zip bytes via output.
    let downloadCmd = "\(ghPath) api \(endpoint) > '\(zipPath)'"
    _ = shell(downloadCmd, timeout: 30)
    guard FileManager.default.fileExists(atPath: zipPath) else { return nil }
    _ = shell("unzip -q '\(zipPath)' -d '\(tmpDir)'", timeout: 15)
    // Step files are named like "1_<step_name>.txt" (1-based index).
    let prefix = String(format: "%d_", stepNumber)
    let fm = FileManager.default
    if let files = try? fm.contentsOfDirectory(atPath: tmpDir),
       let match = files.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".txt") }) {
        let text = try? String(contentsOfFile: tmpDir + "/" + match, encoding: .utf8)
        try? fm.removeItem(atPath: zipPath)
        try? fm.removeItem(atPath: tmpDir)
        return text
    }
    try? fm.removeItem(atPath: zipPath)
    try? fm.removeItem(atPath: tmpDir)
    return nil
}

// MARK: - Private helpers

private struct RunnersEnvelope: Decodable {
    struct RunnerEntry: Decodable {
        let id: Int
        let name: String
        let status: String
        let busy: Bool
        struct Label: Decodable { let name: String }
        let labels: [Label]
    }
    let runners: [RunnerEntry]
}

private func decodeRunners(from data: Data, scope: String) -> [Runner]? {
    guard let envelope = try? JSONDecoder().decode(RunnersEnvelope.self, from: data),
          !envelope.runners.isEmpty else { return nil }
    return envelope.runners.map { entry in
        Runner(
            id: entry.id,
            name: entry.name,
            status: entry.status,
            busy: entry.busy,
            labels: entry.labels.map(\.name),
            metrics: nil
        )
    }
}
