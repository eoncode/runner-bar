import Foundation

// MARK: - GitHub API client

// MARK: Workflow runs

/// Response envelope for the GitHub list-workflow-runs API endpoint.
struct WorkflowRunsResponse: Decodable {
    /// Total number of runs matching the query (may exceed the returned page).
    let totalCount: Int
    /// Runs returned in this page.
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

/// A single GitHub Actions workflow run.
struct WorkflowRun: Decodable, Identifiable {
    let id: Int
    let name: String?
    let status: String?
    let conclusion: String?
    let createdAt: String?
    let updatedAt: String?
    let htmlUrl: String?
    let headSha: String?
    let headBranch: String?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlUrl = "html_url"
        case headSha = "head_sha"
        case headBranch = "head_branch"
    }
}

// MARK: Jobs

/// Response envelope for the GitHub list-jobs-for-workflow-run API endpoint.
struct WorkflowJobsResponse: Decodable {
    let jobs: [WorkflowJob]
}

/// A single job within a workflow run.
struct WorkflowJob: Decodable, Identifiable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let htmlUrl: String?
    let steps: [WorkflowStep]?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case htmlUrl = "html_url"
    }
}

/// A single step within a workflow job.
struct WorkflowStep: Decodable {
    let name: String
    let status: String?
    let conclusion: String?
    let number: Int
    let startedAt: String?
    let completedAt: String?
    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, number
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

// MARK: - New API helpers

/// Fetches the most recent workflow runs for `scope` ("owner/repo").
func fetchWorkflowRuns(scope: String, limit: Int = 20) -> [WorkflowRun] {
    let cmd = "/opt/homebrew/bin/gh api repos/\(scope)/actions/runs?per_page=\(limit)"
    let output = shell(cmd)
    guard let data = output.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode(WorkflowRunsResponse.self, from: data))?.workflowRuns ?? []
}

/// Fetches the jobs for a specific workflow run.
func fetchJobs(runID: Int, scope: String) -> [WorkflowJob] {
    let cmd = "/opt/homebrew/bin/gh api repos/\(scope)/actions/runs/\(runID)/jobs"
    let output = shell(cmd)
    guard let data = output.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode(WorkflowJobsResponse.self, from: data))?.jobs ?? []
}

/// Cancels a workflow run via the GitHub API.
func cancelRun(runID: Int, scope: String) -> Bool {
    let cmd = "/opt/homebrew/bin/gh api --method POST repos/\(scope)/actions/runs/\(runID)/cancel"
    let output = shell(cmd)
    return output.isEmpty || !output.lowercased().contains("error")
}

/// Re-runs all jobs in a workflow run.
func rerunWorkflow(runID: Int, scope: String) -> Bool {
    let cmd = "/opt/homebrew/bin/gh api --method POST repos/\(scope)/actions/runs/\(runID)/rerun"
    let output = shell(cmd)
    return output.isEmpty || !output.lowercased().contains("error")
}

/// Re-runs only the failed (and cancelled) jobs in a workflow run.
func rerunFailedJobs(runID: Int, scope: String) -> Bool {
    let cmd = "/opt/homebrew/bin/gh api --method POST repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs"
    let output = shell(cmd)
    return output.isEmpty || !output.lowercased().contains("error")
}

// MARK: - Compatibility shims
// These bridge legacy call sites that still use the old free-function API.
// Do not remove until all call sites have been migrated to the new API.

/// Locates the `gh` binary at the standard Homebrew / system paths.
func ghBinaryPath() -> String? {
    let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Global flag set to `true` when the GitHub API returns a rate-limit response.
/// Reset to `false` at the start of each poll cycle.
var ghIsRateLimited = false

/// Calls the GitHub API and returns the raw JSON data, or `nil` on error.
/// Sets `ghIsRateLimited = true` when a 403/429 rate-limit response is detected.
@discardableResult
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard let ghPath = ghBinaryPath() else { return nil }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", endpoint]
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return nil }
    let timeoutItem = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let str = String(data: data, encoding: .utf8),
       str.contains("API rate limit exceeded") || str.contains("rate limit") {
        ghIsRateLimited = true
    }
    return data.isEmpty ? nil : data
}

/// Issues a POST to a GitHub API endpoint. Returns `true` on apparent success.
@discardableResult
func ghPost(_ endpoint: String, timeout: TimeInterval = 30) -> Bool {
    guard let ghPath = ghBinaryPath() else { return false }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", "--method", "POST", endpoint]
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return false }
    let timeoutItem = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return !output.lowercased().contains("error")
}

/// Extracts "owner/repo" from a GitHub HTML URL such as
/// `https://github.com/owner/repo/actions/runs/…`.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard
        let s = urlString,
        let url = URL(string: s),
        url.host == "github.com",
        url.pathComponents.count >= 3
    else { return nil }
    // pathComponents[0] == "/", [1] == owner, [2] == repo
    return "\(url.pathComponents[1])/\(url.pathComponents[2])"
}

/// Extracts the numeric run ID from a GitHub HTML URL such as
/// `https://github.com/owner/repo/actions/runs/123456789/jobs/…`.
func runIDFromHtmlUrl(_ urlString: String?) -> Int? {
    guard let s = urlString else { return nil }
    let parts = s.components(separatedBy: "/")
    for (i, part) in parts.enumerated() where part == "runs" {
        if i + 1 < parts.count, let id = Int(parts[i + 1]) { return id }
    }
    return nil
}

/// Fetches the plain-text log for a single step within a job.
/// Returns `nil` when the step log is unavailable or the CLI call fails.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard let data = ghAPI("repos/\(scope)/actions/jobs/\(jobID)/logs"),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    // The raw log is a flat text blob; return it and let call sites slice by step.
    return text.isEmpty ? nil : text
}

/// Fetches all active (in-progress + queued) jobs for a given scope.
/// Returns an empty array on error; used by `RunnerStoreState.buildJobState`.
func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    guard
        let data = ghAPI("repos/\(scope)/actions/runs?status=in_progress&per_page=100"),
        let runsResponse = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
    else { return [] }

    let iso = ISO8601DateFormatter()
    var jobs: [ActiveJob] = []

    for run in runsResponse.workflowRuns {
        guard
            let jobData = ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=100"),
            let jobsResponse = try? JSONDecoder().decode(WorkflowJobsResponse.self, from: jobData)
        else { continue }
        for wj in jobsResponse.jobs {
            guard let htmlUrl = wj.htmlUrl else { continue }
            let steps: [JobStep] = (wj.steps ?? []).map {
                JobStep(
                    name: $0.name,
                    status: $0.status ?? "queued",
                    conclusion: $0.conclusion,
                    number: $0.number,
                    startedAt: $0.startedAt.flatMap { iso.date(from: $0) },
                    completedAt: $0.completedAt.flatMap { iso.date(from: $0) }
                )
            }
            let job = ActiveJob(
                id: wj.id,
                name: wj.name,
                status: wj.status ?? "queued",
                conclusion: wj.conclusion,
                startedAt: wj.startedAt.flatMap { iso.date(from: $0) },
                createdAt: run.createdAt.flatMap { iso.date(from: $0) },
                completedAt: wj.completedAt.flatMap { iso.date(from: $0) },
                htmlUrl: htmlUrl,
                isDimmed: false,
                steps: steps,
                runnerName: nil
            )
            jobs.append(job)
        }
    }
    return jobs
}

/// Fetches all self-hosted runners registered for the given scope.
/// Returns an empty array on error; used by `RunnerStore.fetchAndEnrichRunners`.
func fetchRunners(for scope: String) -> [Runner] {
    // Determine if this is an org scope (no "/") or a repo scope (contains "/").
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners?per_page=100"
    } else {
        endpoint = "orgs/\(scope)/actions/runners?per_page=100"
    }
    guard
        let data = ghAPI(endpoint),
        let decoded = try? JSONDecoder().decode(RunnersResponse.self, from: data)
    else { return [] }
    return decoded.runners
}
