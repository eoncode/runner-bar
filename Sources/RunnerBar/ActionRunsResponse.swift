import Foundation

// MARK: - ActionRunsResponse

/// Decodable envelope for `GET /repos/{owner}/{repo}/actions/runs` responses.
struct ActionRunsResponse: Codable {
    /// The array of workflow run payloads returned by the API.
    let workflowRuns: [RunPayload]
    /// Maps `workflow_runs` JSON key to `workflowRuns`.
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

// MARK: - RunPayload

/// A single workflow run as returned by the GitHub Actions REST API.
struct RunPayload: Codable {
    /// Unique numeric ID for this workflow run.
    let id: Int
    /// Display name of the workflow.
    let name: String
    /// Current status: `queued`, `in_progress`, or `completed`.
    let status: String
    /// Final result when `status == "completed"`: `success`, `failure`, `cancelled`, etc.
    let conclusion: String?
    /// The branch the workflow ran on.
    let headBranch: String?
    /// Full SHA of the head commit.
    let headSha: String
    /// Human-readable title shown in the GitHub UI.
    let displayTitle: String?
    /// ISO 8601 timestamp when the run was created.
    let createdAt: String?
    /// ISO 8601 timestamp of the most recent update.
    let updatedAt: String?
    /// URL to the run's page on github.com.
    let htmlUrl: String?
    /// The head commit metadata, if available.
    let headCommit: HeadCommit?
    /// Pull requests associated with this run, if any.
    let pullRequests: [PRRef]?

    /// Maps snake_case JSON keys to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headBranch = "head_branch"
        case headSha = "head_sha"
        case displayTitle = "display_title"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlUrl = "html_url"
        case headCommit = "head_commit"
        case pullRequests = "pull_requests"
    }
}

// MARK: - HeadCommit / PRRef

/// Minimal head-commit payload — only the commit message is needed.
struct HeadCommit: Codable { 
    /// The full commit message.
    let message: String 
}

/// Minimal pull-request reference — only the PR number is needed.
struct PRRef: Codable { 
    /// The pull request number.
    let number: Int 
}

// MARK: - PR label

/// Returns a short human-readable label for the run: `#123` if a PR is linked,
/// a branch-embedded PR number if detectable, or the first 7 chars of the SHA.
func prLabel(from run: RunPayload) -> String {
    if let prRef = run.pullRequests?.first { return "#\(prRef.number)" }
    if let branch = run.headBranch,
       let range = branch.range(of: #"/(\d+)/"#, options: .regularExpression) {
        let digits = branch[range].filter { $0.isNumber }
        return "#\(digits)"
    }
    return String(run.headSha.prefix(7))
}
