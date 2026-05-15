import Foundation

// MARK: - File-level formatter

/// Shared ISO-8601 date formatter for this file.
/// ISO8601DateFormatter is expensive to allocate (loads ICU calendars);
/// keeping one instance avoids repeated allocation on every fetch cycle.
private let iso8601 = ISO8601DateFormatter()

// MARK: - GroupStatus

/// Type-safe status for a workflow run group (commit/PR trigger).
/// Mirrors ci-dash.py's group status derivation logic.
enum GroupStatus {
    /// At least one sibling run is in progress.
    case inProgress
    /// No run is in progress, but at least one is queued.
    case queued
    /// All runs have concluded (or all jobs are done).
    case completed
}

// MARK: - WorkflowRunRef

/// Lightweight reference to a single workflow run inside an ActionGroup.
/// Holds only the data needed for display and job fetching — deliberately
/// minimal so the full job list lives on the parent ActionGroup instead.
struct WorkflowRunRef: Identifiable {
    /// GitHub-assigned run identifier.
    let id: Int
    /// Workflow file name, e.g. “SonarQube”, “vitest”.
    let name: String
    /// Lifecycle status of the run.
    let status: String
    /// Final outcome once the run finishes.
    let conclusion: String?
    /// Deep-link URL on github.com for this run.
    let htmlUrl: String?
}

// MARK: - ActionGroup

/// Represents one **commit / PR trigger**: all GitHub Actions workflow runs
/// that share the same `head_sha`. Mirrors ci-dash.py's “Group” concept from
/// `group_runs()` + `enrich_group()`.
///
/// Hierarchy: ActionGroup → jobs (flat across all sibling runs) → JobStep → log.
/// `ActionDetailView` drills into the flat job list; `JobDetailView`/`StepLogView`
/// are reused unchanged below that.
struct ActionGroup: Identifiable, Equatable {
    /// The Git SHA shared by all sibling runs in this group.
    let headSha: String
    /// Short display label: “#1270” if PR, else “d6281b” (sha[:7]).
    let label: String
    /// Commit/PR message first line (≤40 chars).
    let title: String
    /// Branch name for the head commit, if available.
    let headBranch: String?
    /// Repository scope in `owner/repo` format.
    let repo: String

    /// All sibling workflow runs sharing this `head_sha`.
    var runs: [WorkflowRunRef]

    /// Stable unique key: highest run ID in this group.
    /// Run IDs are unique and monotonically increasing — immune to head_sha collisions
    /// caused by scheduled workflows firing on the same commit.
    var id: String { String(runs.map { $0.id }.max() ?? 0) }

    /// All jobs across every run in this group, fetched and flattened.
    /// This is what `ActionDetailView` renders.
    var jobs: [ActiveJob] = []

    /// Timestamp of the earliest job start across all sibling runs.
    var firstJobStartedAt: Date?
    /// Timestamp of the latest job completion across all sibling runs.
    var lastJobCompletedAt: Date?

    /// Fallback creation time from the representative run.
    var createdAt: Date?

    /// Set to `true` when frozen into `actionGroupCache` after completion.
    var isDimmed: Bool = false

    // MARK: Equatable
    // Identity-based equality: two groups are equal when their stable `id` matches.
    static func == (lhs: ActionGroup, rhs: ActionGroup) -> Bool {
        lhs.id == rhs.id
    }

    /// Returns a copy of this group with a replacement jobs array.
    func withJobs(_ newJobs: [ActiveJob]) -> ActionGroup {
        ActionGroup(
            headSha: headSha,
            label: label,
            title: title,
            headBranch: headBranch,
            repo: repo,
            runs: runs,
            jobs: newJobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt,
            isDimmed: isDimmed
        )
    }

    // MARK: - Derived properties

    /// Group status: in_progress if any run is running; queued if any queued
    /// but none running; completed otherwise.
    var groupStatus: GroupStatus {
        if jobsTotal > 0, jobs.filter({ $0.conclusion != nil }).count == jobsTotal {
            return .completed
        }
        if runs.contains(where: { $0.status == "in_progress" }) { return .inProgress }
        if runs.contains(where: { $0.status == "queued" })      { return .queued }
        return .completed
    }

    /// Group conclusion derived preferentially from jobs, falling back to runs.
    ///
    /// ⚠️ WHY WE USE JOBS, NOT RUNS:
    /// The GitHub API can report a run-level conclusion of “failure” even when every
    /// individual job succeeded (e.g. after a retry). Using job-level conclusions is authoritative.
    ///
    /// Returns nil while jobs are still loading or any job has not yet concluded.
    var conclusion: String? {
        if !jobs.isEmpty {
            guard jobs.allSatisfy({ $0.conclusion != nil }) else { return nil }
            if jobs.contains(where: { $0.conclusion == "failure" })   { return "failure" }
            if jobs.contains(where: { $0.conclusion == "cancelled" }) { return "cancelled" }
            if jobs.contains(where: { $0.conclusion == "skipped" })   { return "skipped" }
            return "success"
        }
        guard runs.allSatisfy({ $0.conclusion != nil }) else { return nil }
        if runs.contains(where: { $0.conclusion == "failure" })   { return "failure" }
        if runs.contains(where: { $0.conclusion == "cancelled" }) { return "cancelled" }
        if runs.contains(where: { $0.conclusion == "skipped" })   { return "skipped" }
        return "success"
    }

    /// Number of jobs with a concluded result across all sibling runs.
    var jobsDone: Int { jobs.filter { $0.conclusion != nil }.count }
    /// Total job count across all sibling runs.
    var jobsTotal: Int { jobs.count }

    /// Human-readable job progress fraction, e.g. “3/5”. Returns “—” while jobs load.
    var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsDone)/\(jobsTotal)" }

    /// Name of the first in-progress job, or first queued, or “—”.
    var currentJobName: String {
        if let job = jobs.first(where: { $0.status == "in_progress" }) { return job.name }
        if let job = jobs.first(where: { $0.status == "queued" })      { return job.name }
        return "—"
    }

    /// Elapsed time derived from min(job.startedAt) → max(job.completedAt).
    var elapsed: String {
        if let start = firstJobStartedAt {
            let end = lastJobCompletedAt ?? Date()
            let sec = Int(end.timeIntervalSince(start))
            guard sec >= 0 else { return "00:00" }
            // swiftlint:disable:next identifier_name
            let mins = sec / 60
            // swiftlint:disable:next identifier_name
            let secs = sec % 60
            return String(format: "%02d:%02d", mins, secs)
        }
        guard let start = createdAt else { return "00:00" }
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        // swiftlint:disable:next identifier_name
        let mins = sec / 60
        // swiftlint:disable:next identifier_name
        let secs = sec % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Runner type

    /// `true` if at least one job in this group ran on a local (self-hosted) runner.
    /// `nil` if no job has been assigned to a runner yet.
    var isLocalGroup: Bool? {
        let known = jobs.compactMap { $0.isLocalRunner }
        guard !known.isEmpty else { return nil }
        return known.contains(true)
    }
}

// MARK: - Codable helpers (private to this file)

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
    let updatedAt: String?
    let htmlUrl: String?
    let headCommit: HeadCommit?
    let pullRequests: [PRRef]?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headBranch    = "head_branch"
        case headSha       = "head_sha"
        case displayTitle  = "display_title"
        case createdAt     = "created_at"
        case updatedAt     = "updated_at"
        case htmlUrl       = "html_url"
        case headCommit    = "head_commit"
        case pullRequests  = "pull_requests"
    }
}

private struct HeadCommit: Codable {
    let message: String
}

private struct PRRef: Codable {
    let number: Int
}

// MARK: - PR label

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

/// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
/// enriches each group with its flattened job list, and returns groups sorted:
/// in_progress first, then queued, then done — newest first.
// swiftlint:disable:next function_body_length cyclomatic_complexity
func fetchActionGroups(for scope: String, cache: [String: ActionGroup] = [:]) -> [ActionGroup] {
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

    var groups: [ActionGroup] = bySha.map { sha, shaRuns in
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
        return ActionGroup(
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
/// ⚠️ Uses `step.number` (API-supplied), NOT `idx + 1`.
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

/// Fetches and decodes jobs for a single run ID.
/// ❌ NEVER add filter=latest — it omits queued jobs not yet started.
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

/// Returns a lower number for higher display priority.
private func statusPriority(_ status: GroupStatus) -> Int {
    switch status {
    case .inProgress: return 0
    case .queued:     return 1
    case .completed:  return 2
    }
}
