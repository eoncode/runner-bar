import Foundation

// MARK: - ActionRunsResponse
struct ActionRunsResponse: Codable {
    let workflowRuns: [RunPayload]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

// MARK: - RunPayload
struct RunPayload: Codable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let headBranch: String?
    let headSha: String
    let displayTitle: String?
    let createdAt: String?
    let updatedAt: String?
    let htmlUrl: String?
    let headCommit: HeadCommit?
    let pullRequests: [PRRef]?

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
struct HeadCommit: Codable { let message: String }
struct PRRef: Codable { let number: Int }

// MARK: - PR label
func prLabel(from run: RunPayload) -> String {
    if let pr = run.pullRequests?.first { return "#\(pr.number)" }
    if let branch = run.headBranch,
       let range = branch.range(of: #"/(\d+)/"#, options: .regularExpression) {
        let digits = branch[range].filter { $0.isNumber }
        return "#\(digits)"
    }
    return String(run.headSha.prefix(7))
}
