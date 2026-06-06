// WorkflowActionGroupFetch.swift
// RunnerBarCore
import Foundation
import os

// MARK: - File-level constants
/// Regex that extracts a PR number from a GitHub merge-ref branch name (e.g. `refs/pull/123/merge`).
private let prNumberPattern = #"/(\d+)/"# // NOSONAR — fixed regex pattern

/// Maximum number of in-progress/inconclusive jobs refreshed concurrently per run.
///
/// Capped to avoid a thundering-herd of single-job API calls when a run has
/// many steps still in-progress simultaneously (e.g. a large matrix job).
private let maxRefreshConcurrency = 3

// MARK: - Codable helpers (private to this file)

/// Response envelope for the workflow runs list API endpoint.
private struct ActionRunsResponse: Codable {
    /// The list of workflow runs returned by the API.
    let workflowRuns: [RunPayload]
    /// Maps the snake_case `workflow_runs` key to the camelCase Swift property.
    enum CodingKeys: String, CodingKey {
        /// Maps `workflow_runs` JSON key to `workflowRuns`.
        case workflowRuns = "workflow_runs"
    }
}

/// Minimal workflow run payload used for group construction.
private struct RunPayload: Codable {
    /// The unique run identifier.
    let id: Int
    /// The workflow name.
    let name: String
    /// The current run status (e.g. `"in_progress"`, `"queued"`, `"completed"`).
    let status: String
    /// The run conclusion, if completed (e.g. `"success"`, `"failure"`).
    let conclusion: String?
    /// The branch name the run is targeting.
    let headBranch: String?
    /// The full SHA of the head commit.
    let headSha: String
    /// The human-readable display title shown in the GitHub UI.
    let displayTitle: String?
    /// ISO-8601 timestamp when the run was created.
    let createdAt: String?
    /// URL to the run in the GitHub web UI.
    let htmlUrl: String?
    /// The head commit metadata.
    let headCommit: HeadCommit?
    /// Pull request references associated with this run.
    let pullRequests: [PRRef]?
    /// CodingKeys mapping snake_case API fields to camelCase Swift properties.
    enum CodingKeys: String, CodingKey {
        /// Maps the `id` JSON field.
        case id
        /// Maps the `name` JSON field.
        case name
        /// Maps the `status` JSON field.
        case status
        /// Maps the `conclusion` JSON field.
        case conclusion
        /// Maps the `head_branch` JSON field.
        case headBranch   = "head_branch"
        /// Maps the `head_sha` JSON field.
        case headSha      = "head_sha"
        /// Maps the `display_title` JSON field.
        case displayTitle = "display_title"
        /// Maps the `created_at` JSON field.
        case createdAt    = "created_at"
        /// Maps the `html_url` JSON field.
        case htmlUrl      = "html_url"
        /// Maps the `head_commit` JSON field.
        case headCommit   = "head_commit"
        /// Maps the `pull_requests` JSON field.
        case pullRequests = "pull_requests"
    }
}

/// The first line of the head commit message, used as a fallback display title.
private struct HeadCommit: Codable {
    /// The full commit message (only the first line is used).
    let message: String
}

/// A pull request reference attached to a workflow run.
private struct PRRef: Codable {
    /// The pull request number.
    let number: Int
}

/// Derives the short display label for an action group row.
///
/// Priority: PR number → branch-embedded number → sha[:7].
/// - Parameter run: The representative `RunPayload` for this group.
/// - Returns: A short label string, e.g. `"#1270"` or `"d6281b"`.
private func prLabel(from run: RunPayload) -> String {
    if let pr = run.pullRequests?.first { return "#\(pr.number)" }
    if let branch = run.headBranch,
       let range = branch.range(of: prNumberPattern, options: .regularExpression) {
        let digits = branch[range].filter { $0.isNumber }
        return "#\(digits)"
    }
    return String(run.headSha.prefix(7))
}

// MARK: - Fetch + Group

/// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
/// enriches each group with its flattened job list, and returns groups sorted:
/// in-progress first, then queued, then completed — newest first within each tier.
///
/// All three status fetches (in_progress, queued, completed) run concurrently.
/// Per-run job fetches within each group also run concurrently.
/// Date parsing goes through `ISO8601DateParser.shared` — one actor, one formatter.
public func fetchActionGroups(for scope: String, cache: [String: WorkflowActionGroup] = [:]) async -> [WorkflowActionGroup] {
    guard scope.contains("/") else {
        log("fetchActionGroups › skipping org scope \(scope)")
        return []
    }

    // Fetch in_progress, queued, and completed runs concurrently.
    async let inProgressData = ghAPI("repos/\(scope)/actions/runs?status=in_progress&per_page=50")
    async let queuedData     = ghAPI("repos/\(scope)/actions/runs?status=queued&per_page=50")
    async let completedData  = ghAPI("repos/\(scope)/actions/runs?status=completed&per_page=100")
    let (ipData, qData, cData) = await (inProgressData, queuedData, completedData)

    var runPayloads: [RunPayload] = []
    var seenIDs = Set<Int>()

    for data in [ipData, qData].compactMap({ $0 }) {
        if let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) {
            for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
                runPayloads.append(run)
            }
        }
    }

    var bySha: [String: [RunPayload]] = [:]
    for run in runPayloads { bySha[run.headSha, default: []].append(run) }

    // Phase 2: fetch recently completed runs and merge into ALL SHA groups.
    // Fix #1041: completed-only SHAs (groups that finished between polls) are
    // now included so they can be routed through the normal cache/display pipeline.
    // De-duplication of old completed groups re-triggering the failure hook is
    // handled upstream by PollResultBuilder.buildGroupState via seenGroupIDs.
    if let data = cData,
       let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) {
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            bySha[run.headSha, default: []].append(run)
        }
    }

    // Build groups concurrently — index-keyed to preserve insertion order.
    let shaEntries = Array(bySha)
    var groups = Array(repeating: WorkflowActionGroup?.none, count: shaEntries.count)
    await withTaskGroup(of: (Int, WorkflowActionGroup).self) { group in
        for (i, (sha, shaRuns)) in shaEntries.enumerated() {
            group.addTask {
                let representative = shaRuns.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }.first!
                let label    = prLabel(from: representative)
                let rawTitle = representative.displayTitle ?? representative.headCommit
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
                let allJobs = await fetchJobsForGroup(shaRuns: shaRuns, scope: scope, cache: cache, sha: sha)
                let starts = allJobs.compactMap { $0.startedAt }
                let ends   = allJobs.compactMap { $0.completedAt }
                // Optional.flatMap does not accept an async closure — use if let.
                let createdAt: Date?
                if let dateStr = representative.createdAt {
                    createdAt = await ISO8601DateParser.shared.parse(dateStr)
                } else {
                    createdAt = nil
                }
                return (i, WorkflowActionGroup(
                    headSha: sha,
                    label: label,
                    title: title,
                    headBranch: representative.headBranch,
                    repo: scope,
                    runs: runs,
                    jobs: allJobs,
                    firstJobStartedAt: starts.min(),
                    lastJobCompletedAt: ends.max(),
                    createdAt: createdAt
                ))
            }
        }
        for await (i, g) in group { groups[i] = g }
    }

    var result = groups.compactMap { $0 }
    result.sort { lhs, rhs in
        let lhsPriority = statusPriority(lhs.groupStatus)
        let rhsPriority = statusPriority(rhs.groupStatus)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
    }
    log("fetchActionGroups › \(result.count) group(s) for \(scope)")
    return result
}

// MARK: - Private helpers

/// Returns the flattened job list for all runs sharing a `head_sha`.
///
/// Uses the SHA-keyed cache when all cached jobs are concluded and none have
/// in-progress steps, avoiding redundant API calls for finished groups.
/// Falls back to a live fetch via `fetchJobsForRun` when the cache is stale or missing.
///
/// Per-run job fetches run concurrently via `withTaskGroup`.
private func fetchJobsForGroup(
    shaRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup],
    sha: String
) async -> [ActiveJob] {
    if let cached = cache[sha],
       !cached.jobs.isEmpty,
       // Both conditions required: a job can be concluded while one of its steps
       // is still marked in-progress (stale step data from a mid-poll snapshot).
       // Serving that cache entry would show a spinning step on an already-finished job.
       cached.jobs.allSatisfy({ $0.conclusion != nil }),
       !cached.jobs.contains(where: { $0.steps.contains { $0.status == JobStatus.inProgress } }) {
        return cached.jobs
    }

    var fetched: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    await withTaskGroup(of: [ActiveJob].self) { group in
        for runID in shaRuns.map({ $0.id }) {
            group.addTask { await fetchJobsForRun(runID, scope: scope) }
        }
        for await jobs in group {
            for job in jobs where seenJobIDs.insert(job.id).inserted {
                fetched.append(job)
            }
        }
    }
    fetched.sort { $0.id < $1.id }
    return fetched
}

/// Fetches and decodes the job list for a single run ID, refreshing any
/// in-progress or inconclusive jobs with a targeted single-job API call.
///
/// - Note: `filter=latest` is intentionally omitted — it drops queued jobs that
///   haven't started yet, causing `jobsTotal` to be lower than the detail view.
///   `per_page=100` is the GitHub API maximum and covers all realistic job counts.
///
/// Refresh calls for in-progress/inconclusive jobs run concurrently,
/// capped at `maxRefreshConcurrency` to avoid a thundering-herd of single-job
/// API calls on runs with many simultaneously in-progress steps.
/// All date parsing goes through `ISO8601DateParser.shared`.
private func fetchJobsForRun(_ runID: Int, scope: String) async -> [ActiveJob] {
    guard let data = await ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
          let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
    else { return [] }

    let initial = await withTaskGroup(of: ActiveJob.self) { group in
        for payload in resp.jobs {
            group.addTask { await ISO8601DateParser.shared.makeJob(from: payload) }
        }
        var out: [ActiveJob] = []
        for await job in group { out.append(job) }
        return out
    }

    // Refresh in-progress/inconclusive jobs concurrently, capped at maxRefreshConcurrency.
    let needsRefresh = initial.enumerated().filter { _, job in
        job.conclusion == nil || job.steps.contains { $0.status == JobStatus.inProgress }
    }.prefix(maxRefreshConcurrency)
    guard !needsRefresh.isEmpty else { return initial }

    var result = initial
    await withTaskGroup(of: (Int, ActiveJob?).self) { group in
        for (idx, job) in needsRefresh {
            group.addTask {
                guard let freshData = await ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
                      let fresh = try? JSONDecoder().decode(JobPayload.self, from: freshData)
                else { return (idx, nil) }
                let freshJob = await ISO8601DateParser.shared.makeJob(from: fresh)
                if fresh.conclusion != nil { return (idx, freshJob) }
                let betterSteps = !freshJob.steps.isEmpty && !freshJob.steps.contains { $0.status == JobStatus.inProgress }
                if betterSteps {
                    return (idx, ActiveJob(
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
                    ))
                }
                return (idx, nil)
            }
        }
        for await (idx, updated) in group {
            if let updated { result[idx] = updated }
        }
    }
    return result
}

/// Returns the sort priority for a `GroupStatus`.
///
/// Lower value = higher display priority (in-progress before queued before completed).
/// - Parameter status: The `GroupStatus` to evaluate.
/// - Returns: An integer priority where `0` = in-progress, `1` = queued, `2` = completed.
private func statusPriority(_ status: GroupStatus) -> Int {
    switch status {
    case .inProgress: return 0
    case .queued:     return 1
    case .completed:  return 2
    }
}
