// WorkflowActionGroupFetch.swift
// RunnerBar
// swiftlint:disable missing_docs
import Foundation
import RunnerBarCore

// MARK: - Codable helpers (private to this file)

/// Shared ISO-8601 date formatter for this file.
/// ISO8601DateFormatter is expensive to allocate (loads ICU calendars);
/// keeping one instance avoids repeated allocation on every fetch cycle.
private let iso8601 = ISO8601DateFormatter()

/// Top-level response envelope for the GitHub Actions workflow runs list endpoint.
private struct ActionRunsResponse: Codable {
    /// The array of workflow run payloads returned by the API.
    let workflowRuns: [RunPayload]
    /// Maps Swift property names to their JSON keys.
    enum CodingKeys: String, CodingKey {
        /// Maps `workflowRuns` to `workflow_runs`.
        case workflowRuns = "workflow_runs"
    }
}

/// Decoded representation of a single GitHub Actions workflow run.
private struct RunPayload: Codable {
    /// The unique run identifier.
    let id: Int
    /// The workflow file name (e.g. "SwiftLint", "SonarQube").
    let name: String
    /// Current run status (e.g. "in_progress", "queued", "completed").
    let status: String
    /// Run conclusion once completed (e.g. "success", "failure"), or nil while running.
    let conclusion: String?
    /// The branch this run was triggered on.
    let headBranch: String?
    /// The commit SHA that triggered this run.
    let headSha: String
    /// Human-readable title shown in the GitHub UI.
    let displayTitle: String?
    /// ISO-8601 timestamp when the run was created.
    let createdAt: String?
    /// ISO-8601 timestamp when the run was last updated.
    let updatedAt: String?
    /// URL to the run detail page on github.com.
    let htmlUrl: String?
    /// The head commit associated with this run.
    let headCommit: HeadCommit?
    /// Pull requests associated with this run, if any.
    let pullRequests: [PRRef]?
    /// Maps Swift property names to their snake_case JSON keys.
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headBranch   = "head_branch"
        case headSha      = "head_sha"
        case displayTitle = "display_title"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
        case htmlUrl      = "html_url"
        case headCommit   = "head_commit"
        case pullRequests = "pull_requests"
    }
}

/// The head commit object nested inside a workflow run payload.
private struct HeadCommit: Codable {
    /// The full commit message.
    let message: String
}

/// A pull request reference nested inside a workflow run payload.
private struct PRRef: Codable {
    /// The pull request number.
    let number: Int
}

/// Derives the short identifier for an action group row.
/// Priority: PR number → branch-embedded number → sha[:7].
private func prLabel(from run: RunPayload) -> String {
    if let pr = run.pullRequests?.first { return "#\(pr.number)" }
    if let branch = run.headBranch,
       let range = branch.range(of: #"/(\d+)/"#, options: .regularExpression) {
        let digits = branch[range].filter { $0.isNumber }
        return "#\(digits)"
    }
    return String(run.headSha.prefix(7))
}

// MARK: - Fetch + Group
// swiftlint:disable:next function_body_length cyclomatic_complexity
/// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
/// enriches each group with its flattened job list, and returns groups sorted:
/// in_progress first, then queued, then done — newest first.
func fetchActionGroups(for scope: String, cache: [String: WorkflowActionGroup] = [:]) -> [WorkflowActionGroup] {
    guard scope.contains("/") else {
        log("fetchActionGroups › skipping org scope \(scope)")
        return []
    }
    var runPayloads: [RunPayload] = []
    var seenIDs = Set<Int>()

    for status in ["in_progress", "queued"] {
        let endpoint = "repos/\(scope)/actions/runs?status=\(status)&per_page=50"
        guard let data = ghAPI(endpoint),
              let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data)
        else { continue }
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            runPayloads.append(run)
        }
    }

    var bySha: [String: [RunPayload]] = [:]
    for run in runPayloads { bySha[run.headSha, default: []].append(run) }

    if let data = ghAPI("repos/\(scope)/actions/runs?status=completed&per_page=100"),
       let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) {
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            if bySha[run.headSha] != nil { bySha[run.headSha]!.append(run) }
        }
    }

    var groups: [WorkflowActionGroup] = bySha.map { sha, shaRuns in
        let rep = shaRuns.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }.first!
        let label    = prLabel(from: rep)
        let rawTitle = rep.displayTitle ?? rep.headCommit
            .map { String($0.message.components(separatedBy: "\n").first ?? "") }
            ?? String(sha.prefix(7))
        let title = String(rawTitle.prefix(40))
        let runs: [WorkflowRunRef] = shaRuns.map {
            WorkflowRunRef(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                conclusion: $0.conclusion,
                htmlUrl: $0.htmlUrl
            )
        }
        let allJobs: [ActiveJob]
        if let cached = cache[sha],
           !cached.jobs.isEmpty,
           cached.jobs.allSatisfy({ $0.conclusion != nil }) &&
           !cached.jobs.contains(where: { $0.steps.contains { $0.status == .inProgress } }) {
            allJobs = cached.jobs
        } else {
            var fetched: [ActiveJob] = []
            var seenJobIDs = Set<Int>()
            for runID in shaRuns.map({ $0.id }) {
                for job in fetchJobsForRun(runID, scope: scope)
                where seenJobIDs.insert(job.id).inserted {
                    fetched.append(job)
                }
            }
            fetched.sort { $0.id < $1.id }
            allJobs = fetched
        }
        let starts = allJobs.compactMap { $0.startedAt }
        let ends   = allJobs.compactMap { $0.completedAt }
        return WorkflowActionGroup(
            headSha: sha,
            label: label,
            title: title,
            headBranch: rep.headBranch,
            repo: scope,
            runs: runs,
            jobs: allJobs,
            firstJobStartedAt: starts.min(),
            lastJobCompletedAt: ends.max(),
            createdAt: rep.createdAt.flatMap { iso8601.date(from: $0) }
        )
    }
    groups.sort { leftGroup, rightGroup in
        let leftPriority  = statusPriority(leftGroup.groupStatus)
        let rightPriority = statusPriority(rightGroup.groupStatus)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        return (leftGroup.createdAt ?? .distantPast) > (rightGroup.createdAt ?? .distantPast)
    }
    log("fetchActionGroups › \(groups.count) group(s) for \(scope)")
    return groups
}

// MARK: - Private helpers

/// Constructs an `ActiveJob` from a decoded `JobPayload`.
/// Delegates to the canonical `makeActiveJob(from:iso:isDimmed:)` factory in
/// `ActiveJob.swift` (RunnerBarCore) — do NOT duplicate logic here.
/// ⚠️ Uses `step.number` (API-supplied sequence number), NOT `idx + 1`.
/// GitHub step numbers can be non-contiguous (e.g. after retries or skipped
/// steps); using the array index would cause `fetchStepLog` to fetch the wrong log.
func makeActiveJob(from jobPayload: JobPayload,
                   iso: ISO8601DateFormatter,
                   isDimmed: Bool = false) -> ActiveJob {
    RunnerBarCore.makeActiveJob(from: jobPayload, iso: iso, isDimmed: isDimmed)
}

/// Fetch and decode jobs for a single run ID.
/// ❌ NEVER add filter=latest back — it omits queued jobs that haven't started yet,
/// causing the main row to show a lower jobsTotal than the detail view.
/// per_page=100 is the GitHub API maximum and covers all realistic job counts.
private func fetchJobsForRun(_ runID: Int, scope: String) -> [ActiveJob] {
    guard let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
          let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
    else { return [] }
    let initial = resp.jobs.map { makeActiveJob(from: $0, iso: iso8601) }
    var result = initial
    var refreshCount = 0
    for idx in result.indices {
        let job = result[idx]
        let needsRefresh = job.conclusion == nil || job.steps.contains { $0.status == .inProgress }
        guard needsRefresh, refreshCount < 3 else { continue }
        refreshCount += 1
        guard let freshData = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: freshData)
        else { continue }
        let freshJob = makeActiveJob(from: fresh, iso: iso8601)
        if fresh.conclusion != nil { result[idx] = freshJob; continue }
        let betterSteps = !freshJob.steps.isEmpty && !freshJob.steps.contains { $0.status == .inProgress }
        if betterSteps {
            result[idx] = ActiveJob(
                id:          job.id,
                name:        job.name,
                htmlUrl:     job.htmlUrl,
                status:      job.status,
                conclusion:  job.conclusion,
                isDimmed:    job.isDimmed,
                runnerName:  freshJob.runnerName ?? job.runnerName,
                scope:       job.scope,
                startedAt:   freshJob.startedAt ?? job.startedAt,
                completedAt: freshJob.completedAt ?? job.completedAt,
                steps:       freshJob.steps
            )
        }
    }
    return result
}

/// Lower number = higher display priority for sort.
private func statusPriority(_ status: GroupStatus) -> Int {
    switch status {
    case .inProgress: return 0
    case .queued:     return 1
    case .completed:  return 2
    }
}
// swiftlint:enable missing_docs
