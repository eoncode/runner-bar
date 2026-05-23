// WorkflowActionGroupFetch.swift
// RunnerBar
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
        /// Maps `id`.
        case id
        /// Maps `name`.
        case name
        /// Maps `status`.
        case status
        /// Maps `conclusion`.
        case conclusion
        /// Maps `headBranch` to `head_branch`.
        case headBranch   = "head_branch"
        /// Maps `headSha` to `head_sha`.
        case headSha      = "head_sha"
        /// Maps `displayTitle` to `display_title`.
        case displayTitle = "display_title"
        /// Maps `createdAt` to `created_at`.
        case createdAt    = "created_at"
        /// Maps `updatedAt` to `updated_at`.
        case updatedAt    = "updated_at"
        /// Maps `htmlUrl` to `html_url`.
        case htmlUrl      = "html_url"
        /// Maps `headCommit` to `head_commit`.
        case headCommit   = "head_commit"
        /// Maps `pullRequests` to `pull_requests`.
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
// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
// enriches each group with its flattened job list, and returns groups sorted:
// in_progress first, then queued, then done — newest first.
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

    // Phase 1: fetch in_progress and queued runs.
    for status in ["in_progress", "queued"] {
        let endpoint = "repos/\(scope)/actions/runs?status=\(status)&per_page=50"
        guard let data = ghAPI(endpoint),
              let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data)
        else { continue }
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            runPayloads.append(run)
        }
    }

    // Group by head_sha.
    var bySha: [String: [RunPayload]] = [:]
    for run in runPayloads { bySha[run.headSha, default: []].append(run) }

    // Phase 2: merge recently completed runs into EXISTING groups only.
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
           !cached.jobs.contains(where: { $0.steps.contains { $0.status == "in_progress" } }) {
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
/// ⚠️ Uses `step.number` (the API-supplied step sequence number), NOT `idx + 1`.
/// GitHub step numbers can be non-contiguous (e.g. after retries or skipped steps);
/// using the array index would cause `fetchStepLog(jobID:stepNumber:)` to fetch the wrong log.
func makeActiveJob(from jobPayload: JobPayload,
                   iso: ISO8601DateFormatter,
                   isDimmed: Bool = false) -> ActiveJob {
    let steps: [JobStep] = (jobPayload.steps ?? []).map { step in
        JobStep(
            id: step.number,
            name: step.name,
            status: step.status,
            conclusion: step.conclusion,
            startedAt: step.startedAt.flatMap { iso.date(from: $0) },
            completedAt: step.completedAt.flatMap { iso.date(from: $0) }
        )
    }
    return ActiveJob(
        id: jobPayload.id,
        name: jobPayload.name,
        status: jobPayload.status,
        conclusion: jobPayload.conclusion,
        startedAt: jobPayload.startedAt.flatMap { iso.date(from: $0) },
        createdAt: jobPayload.createdAt.flatMap { iso.date(from: $0) },
        completedAt: jobPayload.completedAt.flatMap { iso.date(from: $0) },
        htmlUrl: jobPayload.htmlUrl,
        isDimmed: isDimmed,
        steps: steps,
        runnerName: jobPayload.runnerName
    )
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
        let needsRefresh = job.conclusion == nil || job.steps.contains { $0.status == "in_progress" }
        guard needsRefresh, refreshCount < 3 else { continue }
        refreshCount += 1
        guard let freshData = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: freshData)
        else { continue }
        let freshJob = makeActiveJob(from: fresh, iso: iso8601)
        if fresh.conclusion != nil { result[idx] = freshJob; continue }
        let betterSteps = !freshJob.steps.isEmpty && !freshJob.steps.contains { $0.status == "in_progress" }
        if betterSteps {
            result[idx] = ActiveJob(
                id: job.id,
                name: job.name,
                status: job.status,
                conclusion: job.conclusion,
                startedAt: freshJob.startedAt ?? job.startedAt,
                createdAt: freshJob.createdAt ?? job.createdAt,
                completedAt: freshJob.completedAt ?? job.completedAt,
                htmlUrl: job.htmlUrl,
                isDimmed: job.isDimmed,
                steps: freshJob.steps,
                runnerName: freshJob.runnerName ?? job.runnerName
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
