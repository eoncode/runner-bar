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

// MARK: - Legacy compatibility shims

/// Calls the GitHub API and returns raw JSON `Data`, or `nil` on error.
///
/// Returns `nil` for any response that contains a top-level `"message"` key,
/// which is how GitHub signals all API errors (404, 403, 401, rate-limit, etc.).
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    let output = shell("/opt/homebrew/bin/gh api \(endpoint)", timeout: timeout)
    guard !output.isEmpty else { return nil }
    let lower = output.lowercased()
    if lower.hasPrefix("error") { return nil }
    // GitHub wraps every API error in {"message":"..."} — reject any such response
    // regardless of the specific message text (covers 404, 403, 401, rate-limit, etc.)
    if lower.contains("\"message\"") { return nil }
    return output.data(using: .utf8)
}

/// Performs a POST via the GitHub API. Returns `true` on apparent success.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    let output = shell("/opt/homebrew/bin/gh api --method POST \(endpoint)", timeout: 30)
    return !output.lowercased().contains("error")
}

/// Returns the path to the `gh` CLI binary, or `nil` if not found.
func ghBinaryPath() -> String? {
    ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Global rate-limit flag. Set `true` when the API returns a 403/rate-limit response.
var ghIsRateLimited = false

/// Extracts `owner/repo` from a GitHub HTML URL such as
/// `https://github.com/owner/repo/actions/runs/123/job/456`.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    // swiftlint:disable identifier_name
    guard
        let s = urlString,
        let url = URL(string: s),
        url.host == "github.com",
        url.pathComponents.count >= 3
    else { return nil }
    // swiftlint:enable identifier_name
    return "\(url.pathComponents[1])/\(url.pathComponents[2])"
}

/// Extracts the numeric workflow run ID from a GitHub HTML URL.
func runIDFromHtmlUrl(_ url: String?) -> Int? {
    guard let url else { return nil }
    let parts = url.components(separatedBy: "/")
    // swiftlint:disable identifier_name
    for (i, p) in parts.enumerated() where p == "runs" && i + 1 < parts.count {
        return Int(parts[i + 1])
    }
    // swiftlint:enable identifier_name
    return nil
}

// MARK: - Runner payload

/// Response envelope for the GitHub list-self-hosted-runners API.
private struct RunnersResponse: Decodable {
    let runners: [Runner]
}

/// Fetches self-hosted runners for a scope.
///
/// Scope can be:
/// - `"owner/repo"` — repo-level runners  (`/repos/{owner}/{repo}/actions/runners`)
/// - `"owner"`      — org-level runners   (`/orgs/{owner}/actions/runners`)
func fetchRunners(for scope: String) -> [Runner] {
    let parts = scope.split(separator: "/")
    let endpoint: String
    if parts.count >= 2 {
        endpoint = "repos/\(scope)/actions/runners?per_page=100"
    } else {
        endpoint = "orgs/\(scope)/actions/runners?per_page=100"
    }
    log("fetchRunners › endpoint: \(endpoint)", logger: .fetch)
    guard let data = ghAPI(endpoint) else {
        log("fetchRunners › ghAPI returned nil for \(endpoint)", logger: .fetch)
        return []
    }
    let runners = (try? JSONDecoder().decode(RunnersResponse.self, from: data))?.runners ?? []
    log("fetchRunners › decoded \(runners.count) runners from \(scope)", logger: .fetch)
    return runners
}

/// Fetches active/queued jobs for a repo scope.
///
/// Queries in_progress and queued runs then fetches their jobs,
/// returning them as `ActiveJob` values ready for `buildJobState`.
func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    let iso = ISO8601DateFormatter()
    var result: [ActiveJob] = []
    var seenIDs = Set<Int>()

    for status in ["in_progress", "queued"] {
        let endpoint = "repos/\(scope)/actions/runs?status=\(status)&per_page=20"
        log("fetchActiveJobs › endpoint: \(endpoint)", logger: .fetch)
        guard let data = ghAPI(endpoint),
              let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        else {
            log("fetchActiveJobs › ghAPI/decode failed for \(scope) status=\(status)", logger: .fetch)
            continue
        }
        log("fetchActiveJobs › \(resp.workflowRuns.count) runs (\(status)) for \(scope)", logger: .fetch)
        for run in resp.workflowRuns {
            guard let jobData = ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=100"),
                  let jobResp = try? JSONDecoder().decode(JobsResponse.self, from: jobData)
            else { continue }
            for payload in jobResp.jobs where seenIDs.insert(payload.id).inserted {
                result.append(
                    RunnerStore.shared.makeActiveJob(from: payload, iso: iso, isDimmed: false)
                )
            }
        }
    }
    log("fetchActiveJobs › total \(result.count) active jobs for \(scope)", logger: .fetch)
    return result
}

/// Fetches the log text for a single step using the `gh` CLI.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard let ghPath = ghBinaryPath() else { return nil }
    let output = shell("\(ghPath) api repos/\(scope)/actions/jobs/\(jobID)/logs", timeout: 30)
    return output.isEmpty ? nil : output
}
