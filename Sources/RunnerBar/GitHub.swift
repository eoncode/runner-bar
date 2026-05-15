// swiftlint:disable identifier_name vertical_whitespace_opening_braces missing_docs opening_brace
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
var ghIsRateLimited = false

/// Calls the GitHub API and returns the raw JSON data, or `nil` on error.
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

/// Extracts "owner/repo" from a GitHub HTML URL.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard
        let urlStr = urlString,
        let url = URL(string: urlStr),
        url.host == "github.com",
        url.pathComponents.count >= 3
    else { return nil }
    return "\(url.pathComponents[1])/\(url.pathComponents[2])"
}

/// Extracts the numeric run ID from a GitHub HTML URL.
func runIDFromHtmlUrl(_ urlString: String?) -> Int? {
    guard let urlStr = urlString else { return nil }
    let parts = urlStr.components(separatedBy: "/")
    for (idx, part) in parts.enumerated() where part == "runs" {
        if idx + 1 < parts.count, let runId = Int(parts[idx + 1]) { return runId }
    }
    return nil
}

/// Fetches the plain-text log for a single step within a job.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard let data = ghAPI("repos/\(scope)/actions/jobs/\(jobID)/logs"),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text.isEmpty ? nil : text
}

/// Fetches all active (in-progress + queued) jobs for a given scope.
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
        for workflowJob in jobsResponse.jobs {
            guard let htmlUrl = workflowJob.htmlUrl else { continue }
            let steps: [JobStep] = (workflowJob.steps ?? []).map {
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
                id: workflowJob.id,
                name: workflowJob.name,
                status: workflowJob.status ?? "queued",
                conclusion: workflowJob.conclusion,
                startedAt: workflowJob.startedAt.flatMap { iso.date(from: $0) },
                createdAt: run.createdAt.flatMap { iso.date(from: $0) },
                completedAt: workflowJob.completedAt.flatMap { iso.date(from: $0) },
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
func fetchRunners(for scope: String) -> [Runner] {
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
// swiftlint:enable identifier_name vertical_whitespace_opening_braces missing_docs opening_brace
