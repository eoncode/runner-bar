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
