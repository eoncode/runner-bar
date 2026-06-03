// WorkflowActionGroupFetch.swift
// RunnerBarCore
import Foundation
import os

// MARK: - File-level constants
/// Regex that extracts a PR number from a GitHub merge-ref branch name (e.g. `refs/pull/123/merge`).
private let prNumberPattern = #"/(\d+)/"# // NOSONAR — fixed regex pattern

// MARK: - Codable helpers (private to this file)

// Shared ISO-8601 date formatter for this file.
// ISO8601DateFormatter is expensive to allocate (loads ICU calendars);
// keeping one instance avoids repeated allocation on every fetch cycle.
// Safety: protected by iso8601Lock.

/// A `Sendable` wrapper around `ISO8601DateFormatter`.
/// Required because `ISO8601DateFormatter` is not `Sendable` itself.
private struct SendableFormatter: @unchecked Sendable {
    /// The internal formatter instance.
    let iso = ISO8601DateFormatter()
}

/// Lock protecting the shared `ISO8601DateFormatter` instance.
private let iso8601Lock = OSAllocatedUnfairLock(initialState: SendableFormatter())

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
    /// The workflow file name (e.g. `"SwiftLint"`, `"SonarQube"`).
    let name: String
    /// Current run status (e.g. `"in_progress"`, `"queued"`, `"completed"`).
    let status: String
    /// Run conclusion once completed (e.g. `"success"`, `"failure"`), or `nil` while running.
    let conclusion: String?
    /// The branch this run was triggered on.
    let headBranch: String?
    /// The commit SHA that triggered this run.
    let headSha: String
    /// Human-readable title shown in the GitHub UI.
    let displayTitle: String?
    /// ISO-8601 timestamp when the run was created.
    let createdAt: String?
    /// URL to the run detail page on github.com.
    let htmlUrl: String?
    /// The head commit associated with this run.
    let headCommit: HeadCommit?
    /// Pull requests associated with this run, if any.
    let pullRequests: [PRRef]?
    /// Maps Swift property names to their snake_case JSON keys.
    enum CodingKeys: String, CodingKey {
        /// Direct-mapped keys whose JSON names match their Swift property names.
        case id, name, status, conclusion
        /// JSON key `head_branch`.
        case headBranch   = "head_branch"
        /// JSON key `head_sha`.
        case headSha      = "head_sha"
        /// JSON key `display_title`.
        case displayTitle = "display_title"
        /// JSON key `created_at`.
        case createdAt    = "created_at"
        /// JSON key `html_url`.
        case htmlUrl      = "html_url"
        /// JSON key `head_commit`.
        case headCommit   = "head_commit"
        /// JSON key `pull_requests`.
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

/// Parses an ISO-8601 date string using the shared thread-safe formatter.
private func parseCreatedAt(_ dateStr: String) -> Date? {
    iso8601Lock.withLock { $0.iso.date(from: dateStr) }
}

// MARK: - Fetch + Group

/// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
/// enriches each group with its flattened job list, and returns groups sorted:
/// in-progress first, then queued, then completed — newest first within each tier.
///
/// - Parameters:
///   - scope: The `owner/repo` string identifying the repository scope.
///   - cache: SHA-keyed group cache from the previous poll cycle. Used to skip
///     re-fetching jobs for groups where all jobs are already concluded.
/// - Returns: Sorted `[WorkflowActionGroup]` for the given scope, or `[]` for org scopes.
public func fetchActionGroups(for scope: String, cache: [String: WorkflowActionGroup] = [:]) -> [WorkflowActionGroup] {
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

    // Phase 2: fetch recently completed runs and merge into ALL SHA groups.
    // Fix #1041: completed-only SHAs (groups that finished between polls) are
    // now included so they can be routed through the normal cache/display pipeline.
    // De-duplication of old completed groups re-triggering the failure hook is
    // handled upstream by PollResultBuilder.buildGroupState via seenGroupIDs.
    if let data = ghAPI("repos/\(scope)/actions/runs?status=completed&per_page=100"),
       let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) {
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            bySha[run.headSha, default: []].append(run)
        }
    }

    var groups: [WorkflowActionGroup] = bySha.map { sha, shaRuns in
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
        let allJobs = fetchJobsForGroup(shaRuns: shaRuns, scope: scope, cache: cache, sha: sha)
        let starts = allJobs.compactMap { $0.startedAt }
        let ends   = allJobs.compactMap { $0.completedAt }
        return WorkflowActionGroup(
            headSha: sha,
            label: label,
            title: title,
            headBranch: representative.headBranch,
            repo: scope,
            runs: runs,
            jobs: allJobs,
            firstJobStartedAt: starts.min(),
            lastJobCompletedAt: ends.max(),
            createdAt: representative.createdAt.flatMap(parseCreatedAt)
        )
    }
    groups.sort { lhs, rhs in
        let lhsPriority = statusPriority(lhs.groupStatus)
        let rhsPriority = statusPriority(rhs.groupStatus)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
    }
    log("fetchActionGroups › \(groups.count) group(s) for \(scope)")
    return groups
}

// MARK: - Private helpers

/// Returns the flattened job list for all runs sharing a `head_sha`.
///
/// Uses the SHA-keyed cache when all cached jobs are concluded and none have
/// in-progress steps, avoiding redundant API calls for finished groups.
/// Falls back to a live fetch via `fetchJobsForRun` when the cache is stale
/// or missing.
///
/// - Parameters:
///   - shaRuns: All `RunPayload` values sharing the same `head_sha`.
///   - scope: The `owner/repo` scope string.
///   - cache: SHA-keyed group cache from the previous poll cycle.
///   - sha: The `head_sha` key used to look up the cache entry.
/// - Returns: Deduplicated, ID-sorted `[ActiveJob]` for this group.
private func fetchJobsForGroup(
    shaRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup],
    sha: String
) -> [ActiveJob] {
    if let cached = cache[sha],
       !cached.jobs.isEmpty,
       cached.jobs.allSatisfy({ $0.conclusion != nil }),
       !cached.jobs.contains(where: { $0.steps.contains { $0.status == JobStatus.inProgress } }) {
        return cached.jobs
    }
    var fetched: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    for runID in shaRuns.map({ $0.id }) {
        for job in fetchJobsForRun(runID, scope: scope)
        where seenJobIDs.insert(job.id).inserted {
            fetched.append(job)
        }
    }
    fetched.sort { $0.id < $1.id }
    return fetched
}

/// Fetches and decodes the job list for a single run ID, refreshing any
/// in-progress or inconclusive jobs with a targeted single-job API call.
///
/// - Parameters:
///   - runID: The GitHub Actions run ID.
///   - scope: The `owner/repo` scope string.
/// - Returns: `[ActiveJob]` for this run, or `[]` on network/decode failure.
///
/// - Note: `filter=latest` is intentionally omitted — it drops queued jobs that
///   haven’t started yet, causing `jobsTotal` to be lower than the detail view.
///   `per_page=100` is the GitHub API maximum and covers all realistic job counts.
private func fetchJobsForRun(_ runID: Int, scope: String) -> [ActiveJob] {
    guard let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
          let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
    else { return [] }
    let initial = iso8601Lock.withLock { wrapper in
        resp.jobs.map { makeActiveJob(from: $0, iso: wrapper.iso) }
    }
    var result = initial
    var refreshCount = 0
    for idx in result.indices {
        let job = result[idx]
        let needsRefresh = job.conclusion == nil || job.steps.contains { $0.status == JobStatus.inProgress }
        guard needsRefresh, refreshCount < 3 else { continue }
        refreshCount += 1
        guard let freshData = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: freshData)
        else { continue }
        let freshJob = iso8601Lock.withLock { wrapper in
            makeActiveJob(from: fresh, iso: wrapper.iso)
        }
        if fresh.conclusion != nil { result[idx] = freshJob; continue }
        let betterSteps = !freshJob.steps.isEmpty && !freshJob.steps.contains { $0.status == JobStatus.inProgress }
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
