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
    /// GitHub-assigned numeric run ID.
    let id: Int
    /// Display name of the run (usually the commit title or triggering event).
    let name: String?
    /// Current status: `queued`, `in_progress`, `completed`, etc.
    let status: String?
    /// Terminal conclusion: `success`, `failure`, `cancelled`, `skipped`, etc. Nil while in-progress.
    let conclusion: String?
    /// ISO 8601 timestamp when the run was created.
    let createdAt: String?
    /// ISO 8601 timestamp of the last update.
    let updatedAt: String?
    /// URL to view the run on GitHub.
    let htmlUrl: String?
    /// Short SHA of the head commit that triggered this run.
    let headSha: String?
    /// Human-readable label for the head branch or tag.
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
    /// Jobs returned in this page.
    let jobs: [WorkflowJob]
}

/// A single job within a workflow run.
struct WorkflowJob: Decodable, Identifiable {
    /// GitHub-assigned numeric job ID.
    let id: Int
    /// Display name of the job as defined in the workflow YAML.
    let name: String
    /// Current status of the job.
    let status: String?
    /// Terminal conclusion of the job, nil while running.
    let conclusion: String?
    /// ISO 8601 start timestamp.
    let startedAt: String?
    /// ISO 8601 completion timestamp.
    let completedAt: String?
    /// URL to view the job on GitHub.
    let htmlUrl: String?
    /// Ordered list of steps within this job.
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
    /// Step display name.
    let name: String
    /// Current status of the step.
    let status: String?
    /// Terminal conclusion, nil while running.
    let conclusion: String?
    /// Step number (1-based).
    let number: Int
    /// ISO 8601 start timestamp.
    let startedAt: String?
    /// ISO 8601 completion timestamp.
    let completedAt: String?
    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, number
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

// MARK: - API helpers

/// Fetches the most recent workflow runs for `scope` ("owner/repo").
///
/// - Parameters:
///   - scope: The `owner/repo` slug to query.
///   - limit: Maximum number of runs to return (default 20).
/// - Returns: Array of `WorkflowRun`, or empty on error.
func fetchWorkflowRuns(scope: String, limit: Int = 20) -> [WorkflowRun] {
    let cmd = "/opt/homebrew/bin/gh api repos/\(scope)/actions/runs?per_page=\(limit)"
    let output = shell(cmd)
    guard let data = output.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode(WorkflowRunsResponse.self, from: data))?.workflowRuns ?? []
}

/// Fetches the jobs for a specific workflow run.
///
/// - Parameters:
///   - runID: The numeric GitHub Actions run ID.
///   - scope: The `owner/repo` slug.
/// - Returns: Array of `WorkflowJob`, or empty on error.
func fetchJobs(runID: Int, scope: String) -> [WorkflowJob] {
    let cmd = "/opt/homebrew/bin/gh api repos/\(scope)/actions/runs/\(runID)/jobs"
    let output = shell(cmd)
    guard let data = output.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode(WorkflowJobsResponse.self, from: data))?.jobs ?? []
}

/// Cancels a workflow run via the GitHub API.
///
/// - Parameters:
///   - runID: The numeric run ID to cancel.
///   - scope: The `owner/repo` slug.
/// - Returns: `true` if the API responded with a 2xx status.
func cancelRun(runID: Int, scope: String) -> Bool {
    let cmd = "/opt/homebrew/bin/gh api --method POST repos/\(scope)/actions/runs/\(runID)/cancel"
    let output = shell(cmd)
    return output.isEmpty || !output.lowercased().contains("error")
}

/// Re-runs all jobs in a workflow run.
///
/// - Parameters:
///   - runID: The numeric run ID to re-run.
///   - scope: The `owner/repo` slug.
/// - Returns: `true` on apparent success.
func rerunWorkflow(runID: Int, scope: String) -> Bool {
    let cmd = "/opt/homebrew/bin/gh api --method POST repos/\(scope)/actions/runs/\(runID)/rerun"
    let output = shell(cmd)
    return output.isEmpty || !output.lowercased().contains("error")
}

/// Re-runs only the failed (and cancelled) jobs in a workflow run.
///
/// - Parameters:
///   - runID: The numeric run ID.
///   - scope: The `owner/repo` slug.
/// - Returns: `true` on apparent success.
func rerunFailedJobs(runID: Int, scope: String) -> Bool {
    let cmd = "/opt/homebrew/bin/gh api --method POST repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs"
    let output = shell(cmd)
    return output.isEmpty || !output.lowercased().contains("error")
}
