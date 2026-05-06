import Foundation

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
    let id: Int
    let name: String         // workflow file name, e.g. "SonarQube", "vitest"
    let status: String
    let conclusion: String?
    let htmlUrl: String?
}

// MARK: - ActionGroup

/// Represents one **commit / PR trigger**: all GitHub Actions workflow runs
/// that share the same `head_sha`. Mirrors ci-dash.py's "Group" concept from
/// `group_runs()` + `enrich_group()`.
///
/// Hierarchy: ActionGroup → jobs (flat across all sibling runs) → JobStep → log.
/// `ActionDetailView` drills into the flat job list; `JobDetailView`/`StepLogView`
/// are reused unchanged below that.
struct ActionGroup: Identifiable {
    let headSha: String         // head_sha — kept as the underlying group identity
    let label: String           // "#1270" if PR, else "d6281b" (sha[:7])
    let title: String           // commit/PR message first line (≤40 chars)
    let headBranch: String?
    let repo: String            // owner/repo scope

    /// All sibling workflow runs sharing this `head_sha`.
    var runs: [WorkflowRunRef]

    /// Stable unique key: highest run ID in this group.
    /// Run IDs are unique and monotonically increasing — immune to head_sha collisions
    /// caused by scheduled workflows firing on the same commit.
    var id: String { String(runs.map { $0.id }.max() ?? 0) }

    /// All jobs across every run in this group, fetched and flattened.
    /// This is what `ActionDetailView` renders.
    var jobs: [ActiveJob] = []

    /// Timestamps derived from job data, not run-level API fields.
    /// Mirrors ci-dash.py's `first_job_started_at` / `last_job_completed_at`.
    var firstJobStartedAt: Date?
    var lastJobCompletedAt: Date?

    /// Fallback creation time from the representative run.
    var createdAt: Date?

    /// Set to `true` when frozen into `actionGroupCache` after completion.
    var isDimmed: Bool = false

    /// Returns a copy of this group with a replacement jobs array.
    /// Used in `RunnerStore` to enrich job data without reconstructing the
    /// full struct at every call site.
    func withJobs(_ newJobs: [ActiveJob]) -> ActionGroup {
        ActionGroup(
            headSha: headSha, label: label, title: title, headBranch: headBranch,
            repo: repo, runs: runs, jobs: newJobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt, isDimmed: isDimmed
        )
    }

    // MARK: - Derived properties (match ci-dash.py enrich_group / status_icon)

    /// Group status: in_progress if any run is running; queued if any queued
    /// but none running; completed otherwise.
    /// Also treats the group as completed if all jobs are done, even if the
    /// run-level API status lags behind (mirrors ci-dash.py override).
    var groupStatus: GroupStatus {
        if jobsTotal > 0,
           jobs.filter({ $0.conclusion != nil }).count == jobsTotal { return .completed }
        if runs.contains(where: { $0.status == "in_progress" }) { return .inProgress }
        if runs.contains(where: { $0.status == "queued" }) { return .queued }
        return .completed
    }

    /// Group conclusion: only non-nil when every run has concluded.
    /// Priority: failure > cancelled > skipped > success.
    var conclusion: String? {
        guard runs.allSatisfy({ $0.conclusion != nil }) else { return nil }
        if runs.contains(where: { $0.conclusion == "failure" })   { return "failure" }
        if runs.contains(where: { $0.conclusion == "cancelled" }) { return "cancelled" }
        if runs.contains(where: { $0.conclusion == "skipped" })   { return "skipped" }
        return "success"
    }

    /// Number of jobs with a concluded result across all sibling runs.
    var jobsDone: Int {
        jobs.filter { $0.conclusion == "success" || $0.conclusion == "skipped" }.count
    }

    /// Total job count across all sibling runs.
    var jobsTotal: Int { jobs.count }

    /// Human-readable job progress fraction, e.g. "3/5". Returns "—" while jobs load.
    var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsDone)/\(jobsTotal)" }

    /// Name of the first in-progress job, or first queued, or "—".
    var currentJobName: String {
        if let j = jobs.first(where: { $0.status == "in_progress" }) { return j.name }
        if let j = jobs.first(where: { $0.status == "queued" })      { return j.name }
        return "—"
    }

    /// Elapsed time derived from min(job.startedAt) → max(job.completedAt).
    var elapsed: String {
        if let start = firstJobStartedAt {
            let end = lastJobCompletedAt ?? Date()
            // swiftlint:disable:next identifier_name
            let sec = Int(end.timeIntervalSince(start))
            guard sec >= 0 else { return "00:00" }
            // swiftlint:disable:next identifier_name
            let m = sec / 60; let s = sec % 60
            return String(format: "%02d:%02d", m, s)
        }
        guard let start = createdAt else { return "00:00" }
        // swiftlint:disable:next identifier_name
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        // swiftlint:disable:next identifier_name
        let m = sec / 60; let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Codable helpers (private to this file)

private struct ActionRunsResponse: Codable {
    let workflowRuns: [RunPayload]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
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

private struct HeadCommit: Codable { let message: String }
private struct PRRef: Codable { let number: Int }

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

    let iso = ISO8601DateFormatter()
    var runPayloads: [RunPayload] = []
    var seenIDs = Set<Int>()

    // Phase 1: fetch in_progress and queued runs.
    for status in ["in_progress", "queued"] {
        let endpoint = "repos/\(scope)/actions/runs?status=\(status)&per_page=50"
        guard
            let data = ghAPI(endpoint),
            let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data)
        else { continue }
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            runPayloads.append(run)
        }
    }

    // Group by head_sha.
    var bySha: [String: [RunPayload]] = [:]
    for run in runPayloads {
        bySha[run.headSha, default: []].append(run)
    }

    // Phase 2: merge recently completed runs into EXISTING groups only.
    if let data = ghAPI("repos/\(scope)/actions/runs?status=completed&per_page=100"),
       let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) {
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            if bySha[run.headSha] != nil {
                bySha[run.headSha]!.append(run)
            }
        }
    }

    var groups: [ActionGroup] = bySha.map { sha, shaRuns in
        let rep = shaRuns.sorted {
            ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }.first!

        let label = prLabel(from: rep)
        let rawTitle = rep.displayTitle
            ?? rep.headCommit.map { String($0.message.components(separatedBy: "\n").first ?? "") }
            ?? String(sha.prefix(7))
        let title = String(rawTitle.prefix(40))

        let runs: [WorkflowRunRef] = shaRuns.map {
            WorkflowRunRef(id: $0.id, name: $0.name, status: $0.status,
                           conclusion: $0.conclusion, htmlUrl: $0.htmlUrl)
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
                for job in fetchJobsForRun(runID, scope: scope, iso: iso)
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
            createdAt: rep.createdAt.flatMap { iso.date(from: $0) }
        )
    }

    groups.sort { a, b in
        let aPriority = statusPriority(a.groupStatus)
        let bPriority = statusPriority(b.groupStatus)
        if aPriority != bPriority { return aPriority < bPriority }
        return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
    }

    log("fetchActionGroups › \(groups.count) group(s) for \(scope)")
    return groups
}

// MARK: - Private helpers

/// Constructs an `ActiveJob` from a decoded `JobPayload`.
func makeActiveJob(from j: JobPayload, iso: ISO8601DateFormatter,
                   isDimmed: Bool = false) -> ActiveJob {
    let steps: [JobStep] = (j.steps ?? []).enumerated().map { idx, s in
        JobStep(
            id: idx + 1,
            name: s.name,
            status: s.status,
            conclusion: s.conclusion,
            startedAt: s.startedAt.flatMap { iso.date(from: $0) },
            completedAt: s.completedAt.flatMap { iso.date(from: $0) }
        )
    }
    return ActiveJob(
        id: j.id,
        name: j.name,
        status: j.status,
        conclusion: j.conclusion,
        startedAt: j.startedAt.flatMap { iso.date(from: $0) },
        createdAt: j.createdAt.flatMap { iso.date(from: $0) },
        completedAt: j.completedAt.flatMap { iso.date(from: $0) },
        htmlUrl: j.htmlUrl,
        isDimmed: isDimmed,
        steps: steps
    )
}

/// Fetch and decode jobs for a single run ID.
private func fetchJobsForRun(_ runID: Int, scope: String, iso: ISO8601DateFormatter) -> [ActiveJob] {
    guard
        let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?filter=latest&per_page=100"),
        let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
    else { return [] }

    let initial = resp.jobs.map { makeActiveJob(from: $0, iso: iso) }

    var result = initial
    var refreshCount = 0
    for i in result.indices {
        let job = result[i]
        let needsRefresh = job.conclusion == nil
            || job.steps.contains { $0.status == "in_progress" }
        guard needsRefresh, refreshCount < 3 else { continue }
        refreshCount += 1
        guard
            let freshData = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
            let fresh     = try? JSONDecoder().decode(JobPayload.self, from: freshData)
        else { continue }

        let freshJob = makeActiveJob(from: fresh, iso: iso)

        if fresh.conclusion != nil {
            result[i] = freshJob
            continue
        }
        let betterSteps = !freshJob.steps.isEmpty
            && !freshJob.steps.contains { $0.status == "in_progress" }
        if betterSteps {
            result[i] = ActiveJob(
                id: job.id,
                name: job.name,
                status: job.status,
                conclusion: job.conclusion,
                startedAt: freshJob.startedAt ?? job.startedAt,
                createdAt: freshJob.createdAt ?? job.createdAt,
                completedAt: freshJob.completedAt ?? job.completedAt,
                htmlUrl: job.htmlUrl,
                isDimmed: job.isDimmed,
                steps: freshJob.steps
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
