import Foundation

// MARK: - GitHub legacy compatibility shims

// MARK: - gh binary path

/// Returns the path to the `gh` CLI binary, searching common Homebrew locations.
func ghBinaryPath() -> String? {
    let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// MARK: - Rate-limit flag

/// Global flag set to `true` when a 403/rate-limit response is detected.
var ghIsRateLimited = false

// MARK: - Generic REST helpers

/// Calls `gh api <endpoint>` and returns the raw response bytes, or `nil` on error.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard let ghPath = ghBinaryPath() else { return nil }
    let output = shell("\(ghPath) api \(endpoint)", timeout: timeout)
    guard !output.isEmpty else { return nil }
    if output.contains("\"message\":") && output.contains("API rate limit") {
        ghIsRateLimited = true
        return nil
    }
    return output.data(using: .utf8)
}

/// Calls `gh api --method POST <endpoint>` and returns `true` on apparent success.
@discardableResult
func ghPost(_ endpoint: String, timeout: TimeInterval = 30) -> Bool {
    guard let ghPath = ghBinaryPath() else { return false }
    let output = shell("\(ghPath) api --method POST \(endpoint)", timeout: timeout)
    return !output.lowercased().contains("error") && !output.lowercased().contains("failed")
}

// MARK: - URL-parsing helpers

/// Extracts `owner/repo` from a GitHub HTML URL string.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    // swiftlint:disable identifier_name
    guard let s = urlString,
          let url = URL(string: s),
          url.host == "github.com",
          url.pathComponents.count >= 3
    else { return nil }
    // swiftlint:enable identifier_name
    let parts = url.pathComponents
    return "\(parts[1])/\(parts[2])"
}

/// Extracts the numeric run ID from a GitHub Actions HTML URL.
func runIDFromHtmlUrl(_ urlString: String?) -> Int? {
    // swiftlint:disable identifier_name
    guard let s = urlString else { return nil }
    let parts = s.components(separatedBy: "/")
    for (i, part) in parts.enumerated() where part == "runs" && i + 1 < parts.count {
        return Int(parts[i + 1])
    }
    // swiftlint:enable identifier_name
    return nil
}

// MARK: - High-level fetchers

/// Fetches in-progress and recently queued jobs for a repo scope.
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
func fetchRunners(for scope: String) -> [Runner] {
    let repoEndpoint = "repos/\(scope)/actions/runners?per_page=100"
    if let data = ghAPI(repoEndpoint),
       let runners = decodeRunners(from: data, scope: scope), !runners.isEmpty {
        return runners
    }
    let org = scope.contains("/") ? String(scope.split(separator: "/").first ?? Substring(scope)) : scope
    let orgEndpoint = "orgs/\(org)/actions/runners?per_page=100"
    guard let data = ghAPI(orgEndpoint),
          let runners = decodeRunners(from: data, scope: scope) else { return [] }
    return runners
}

/// Fetches the log text for a specific step inside a job.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard let ghPath = ghBinaryPath() else { return nil }
    let tmpDir = NSTemporaryDirectory() + "runnerbar_logs_\(jobID)"
    let zipPath = tmpDir + ".zip"
    try? FileManager.default.removeItem(atPath: zipPath)
    try? FileManager.default.removeItem(atPath: tmpDir)
    let endpoint = "repos/\(scope)/actions/jobs/\(jobID)/logs"
    let downloadCmd = "\(ghPath) api \(endpoint) > '\(zipPath)'"
    _ = shell(downloadCmd, timeout: 30)
    guard FileManager.default.fileExists(atPath: zipPath) else { return nil }
    _ = shell("unzip -q '\(zipPath)' -d '\(tmpDir)'", timeout: 15)
    let prefix = String(format: "%d_", stepNumber)
    // swiftlint:disable identifier_name
    let fm = FileManager.default
    if let files = try? fm.contentsOfDirectory(atPath: tmpDir),
       let match = files.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".txt") }) {
        let text = try? String(contentsOfFile: tmpDir + "/" + match, encoding: .utf8)
        try? fm.removeItem(atPath: zipPath)
        try? fm.removeItem(atPath: tmpDir)
        // swiftlint:enable identifier_name
        return text
    }
    try? FileManager.default.removeItem(atPath: zipPath)
    try? FileManager.default.removeItem(atPath: tmpDir)
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
