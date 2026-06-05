// WorkflowActionGroupFetch.swift
// RunnerBarCore
import Foundation
import os

// MARK: - File-level constants
/// Regex that extracts a PR number from a GitHub merge-ref branch name (e.g. `refs/pull/123/merge`).
private let prNumberPattern = #"/(\d+)/"# // NOSONAR — fixed regex pattern

// MARK: - Codable helpers (private to this file)

/// A `Sendable` wrapper around `ISO8601DateFormatter`.
private struct SendableFormatter: @unchecked Sendable {
    let iso = ISO8601DateFormatter()
}

/// Lock protecting the shared `ISO8601DateFormatter` instance.
private let iso8601Lock = OSAllocatedUnfairLock(initialState: SendableFormatter())

private struct ActionRunsResponse: Codable {
    let workflowRuns: [RunPayload]
    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct RunPayload: Codable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let headBranch: String?
    let headSha: String
    let displayTitle: String?
    let createdAt: String?
    let htmlUrl: String?
    let headCommit: HeadCommit?
    let pullRequests: [PRRef]?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headBranch   = "head_branch"
        case headSha      = "head_sha"
        case displayTitle = "display_title"
        case createdAt    = "created_at"
        case htmlUrl      = "html_url"
        case headCommit   = "head_commit"
        case pullRequests = "pull_requests"
    }
}

private struct HeadCommit: Codable {
    let message: String
}

private struct PRRef: Codable {
    let number: Int
}

private func prLabel(from run: RunPayload) -> String {
    if let pr = run.pullRequests?.first { return "#\(pr.number)" }
    if let branch = run.headBranch,
       let range = branch.range(of: prNumberPattern, options: .regularExpression) {
        let digits = branch[range].filter { $0.isNumber }
        return "#\(digits)"
    }
    return String(run.headSha.prefix(7))
}

private func parseCreatedAt(_ dateStr: String) -> Date? {
    iso8601Lock.withLock { $0.iso.date(from: dateStr) }
}

// MARK: - Fetch + Group

/// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
/// enriches each group with its flattened job list, and returns groups sorted:
/// in-progress first, then queued, then completed — newest first within each tier.
///
/// All three status fetches (in_progress, queued, completed) run concurrently.
/// Per-run job fetches within each group also run concurrently.
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

    // Merge completed runs.
    if let data = cData,
       let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) {
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            bySha[run.headSha, default: []].append(run)
        }
    }

    // Build groups concurrently — use index keys so results are reconstructed
    // in insertion order, not network-latency order (prevents UI churn within
    // the same statusPriority tier across polls).
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
                    createdAt: representative.createdAt.flatMap(parseCreatedAt)
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
/// Per-run job fetches run concurrently via `withTaskGroup`.
private func fetchJobsForGroup(
    shaRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup],
    sha: String
) async -> [ActiveJob] {
    if let cached = cache[sha],
       !cached.jobs.isEmpty,
       cached.jobs.allSatisfy({ $0.conclusion != nil }),
       !cached.jobs.contains(where: { $0.steps.contains { $0.status == JobStatus.inProgress } }) {
        return cached.jobs
    }

    // Fetch jobs for all run IDs concurrently.
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

/// Fetches and decodes the job list for a single run ID.
/// Refresh calls for in-progress/inconclusive jobs run concurrently (capped at 3).
private func fetchJobsForRun(_ runID: Int, scope: String) async -> [ActiveJob] {
    guard let data = await ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
          let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
    else { return [] }

    let initial = iso8601Lock.withLock { wrapper in
        resp.jobs.map { makeActiveJob(from: $0, iso: wrapper.iso) }
    }

    // Refresh in-progress/inconclusive jobs concurrently.
    // Filter first, then cap at 3 — the cap is a rate guard on API calls,
    // not a positional guard (old code did prefix(3).filter which silently
    // skipped jobs at index >=3 even if they needed refresh).
    let needsRefresh = initial.enumerated().filter { _, job in
        job.conclusion == nil || job.steps.contains { $0.status == JobStatus.inProgress }
    }.prefix(3)
    guard !needsRefresh.isEmpty else { return initial }

    var result = initial
    await withTaskGroup(of: (Int, ActiveJob?).self) { group in
        for (idx, job) in needsRefresh {
            group.addTask {
                guard let freshData = await ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
                      let fresh = try? JSONDecoder().decode(JobPayload.self, from: freshData)
                else { return (idx, nil) }
                let freshJob = iso8601Lock.withLock { wrapper in
                    makeActiveJob(from: fresh, iso: wrapper.iso)
                }
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
private func statusPriority(_ status: GroupStatus) -> Int {
    switch status {
    case .inProgress: return 0
    case .queued:     return 1
    case .completed:  return 2
    }
}
