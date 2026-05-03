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
    let id: String              // head_sha — stable, unique group key
    let label: String           // "#1270" if PR, else "d6281b" (sha[:7])
    let title: String           // commit/PR message first line (≤40 chars)
    let headBranch: String?
    let repo: String            // owner/repo scope

    /// All sibling workflow runs sharing this `head_sha`.
    var runs: [WorkflowRunRef]

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
            id: id, label: label, title: title, headBranch: headBranch,
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
        // Override: all jobs done → completed, regardless of run API lag.
        if jobsTotal > 0 && jobsDone == jobsTotal { return .completed }
        if runs.contains(where: { $0.status == "in_progress" }) { return .inProgress }
        if runs.contains(where: { $0.status == "queued" }) { return .queued }
        return .completed
    }

    /// Group conclusion: only non-nil when every run has concluded.
    /// Priority: failure > cancelled > skipped > success.
    /// (Matches ci-dash.py status_icon precedence.)
    var conclusion: String? {
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

    /// Human-readable job progress fraction, e.g. "3/5". Returns "—" while jobs load.
    var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsDone)/\(jobsTotal)" }

    /// Name of the first in-progress job, or first queued, or "—".
    /// Mirrors ci-dash.py's `current` field in `enrich_group()`.
    var currentJobName: String {
        if let j = jobs.first(where: { $0.status == "in_progress" }) { return j.name }
        if let j = jobs.first(where: { $0.status == "queued" })      { return j.name }
        return "—"
    }

    /// Elapsed time derived from min(job.startedAt) → max(job.completedAt),
    /// matching ci-dash.py's `enrich_group()` elapsed logic exactly.
    /// Falls back to wall-clock time from `createdAt` while jobs haven't started.
    var elapsed: String {
        if let start = firstJobStartedAt {
            let end = lastJobCompletedAt ?? Date()
            let sec = Int(end.timeIntervalSince(start))
            guard sec >= 0 else { return "00:00" }
            let m = sec / 60; let s = sec % 60
            return String(format: "%02d:%02d", m, s)
        }
        // Jobs not yet started — use run creation time as rough proxy.
        guard let start = createdAt else { return "00:00" }
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
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

private struct HeadCommit: Codable { let message: String }
private struct PRRef: Codable { let number: Int }

// MARK: - PR label

/// Derives the short identifier for an action group row.
/// Priority: PR number → branch-embedded number → sha[:7].
/// Mirrors ci-dash.py's `pr_label_from_run()`.
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
/// enriches each group with its flattened job list, and returns up to `limit`
/// groups sorted: in_progress first, then queued, then done — newest first.
///
/// Mirrors ci-dash.py's `group_runs()` + `enrich_group()`.
///
/// Org scopes are skipped — the GitHub Jobs API requires a repo-scoped endpoint.
func fetchActionGroups(for scope: String) -> [ActionGroup] {
    guard scope.contains("/") else {
        log("fetchActionGroups › skipping org scope \(scope)")
        return []
    }

    let iso = ISO8601DateFormatter()
    var runPayloads: [RunPayload] = []
    var seenIDs = Set<Int>()

    // Phase 1: fetch in_progress and queued runs — these seed the group dict.
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

    // Group by head_sha — mirrors ci-dash.py's group_runs().
    // Phase 1 runs seed the dict; only these shas become visible groups.
    var bySha: [String: [RunPayload]] = [:]
    for run in runPayloads {
        bySha[run.headSha, default: []].append(run)
    }

    // Phase 2: fetch recently completed runs and merge into EXISTING groups only.
    // As individual sibling workflow files finish, their run_ids vanish from the
    // in_progress/queued pages — without this merge, jobsTotal shrinks each poll.
    // Mirrors ci-dash.py's prev_completed merge that keeps groups stable.
    // ⚠️ We do NOT add new keys to bySha here — only backfill known shas.
    if let data = ghAPI("repos/\(scope)/actions/runs?status=completed&per_page=100"),
       let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) {
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted {
            if bySha[run.headSha] != nil {
                bySha[run.headSha]!.append(run)
            }
        }
    }

    // Build ActionGroup for each sha bucket.
    var groups: [ActionGroup] = bySha.map { sha, shaRuns in
        // Representative run = most recently created.
        let rep = shaRuns.sorted {
            ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }.first!

        let label = prLabel(from: rep)

        // Title: prefer display_title → head_commit.message first line → sha[:7].
        let rawTitle = rep.displayTitle
            ?? rep.headCommit.map { String($0.message.components(separatedBy: "\n").first ?? "") }
            ?? String(sha.prefix(7))
        let title = String(rawTitle.prefix(40))

        let runs: [WorkflowRunRef] = shaRuns.map {
            WorkflowRunRef(id: $0.id, name: $0.name, status: $0.status,
                           conclusion: $0.conclusion, htmlUrl: $0.htmlUrl)
        }

        // Fetch and flatten jobs for all run IDs in this group.
        var allJobs: [ActiveJob] = []
        var seenJobIDs = Set<Int>()
        for runID in shaRuns.map({ $0.id }) {
            let fetched = fetchJobsForRun(runID, scope: scope, iso: iso)
            for job in fetched where seenJobIDs.insert(job.id).inserted {
                allJobs.append(job)
            }
        }

        // Sort jobs by id ascending — matches yml definition order (#101).
        allJobs.sort { $0.id < $1.id }

        // Derive timestamps from job data (matches enrich_group()).
        let starts = allJobs.compactMap { $0.startedAt }
        let ends   = allJobs.compactMap { $0.completedAt }

        return ActionGroup(
            id:                  sha,
            label:               label,
            title:               title,
            headBranch:          rep.headBranch,
            repo:                scope,
            runs:                runs,
            jobs:                allJobs,
            firstJobStartedAt:   starts.min(),
            lastJobCompletedAt:  ends.max(),
            createdAt:           rep.createdAt.flatMap { iso.date(from: $0) }
        )
    }

    // Sort: active first (in_progress → queued), then done, each sub-group newest first.
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
/// Shared by the initial batch map and the second-pass re-fetch so both
/// paths produce identical structs — prevents drift between the two (#102/#103).
private func makeActiveJob(from j: JobPayload, iso: ISO8601DateFormatter,
                            isDimmed: Bool = false) -> ActiveJob {
    let steps: [JobStep] = (j.steps ?? []).enumerated().map { idx, s in
        JobStep(
            id:          idx + 1,
            name:        s.name,
            status:      s.status,
            conclusion:  s.conclusion,
            startedAt:   s.startedAt.flatMap   { iso.date(from: $0) },
            completedAt: s.completedAt.flatMap  { iso.date(from: $0) }
        )
    }
    return ActiveJob(
        id:          j.id,
        name:        j.name,
        status:      j.status,
        conclusion:  j.conclusion,
        startedAt:   j.startedAt.flatMap   { iso.date(from: $0) },
        createdAt:   j.createdAt.flatMap   { iso.date(from: $0) },
        completedAt: j.completedAt.flatMap { iso.date(from: $0) },
        htmlUrl:     j.htmlUrl,
        isDimmed:    isDimmed,
        steps:       steps
    )
}

/// Fetch and decode jobs for a single run ID. Reuses the internal
/// JobsResponse/JobPayload/StepPayload types from ActiveJob.swift.
///
/// Second pass: any job that still has no conclusion — or whose steps still
/// contain an "in_progress" entry — is re-fetched individually via the single-job
/// endpoint.  This resolves three stale-data classes the batch endpoint produces:
///   #102  — queued job lingers / steps missing after the run completes.
///   #103 A+B — GitHub-hosted runner jobs with missing step data.
///   #103 C  — jobs whose steps are still "in_progress" after completion.
private func fetchJobsForRun(_ runID: Int, scope: String, iso: ISO8601DateFormatter) -> [ActiveJob] {
    guard
        let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?filter=latest&per_page=100"),
        let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
    else { return [] }

    // Initial map via shared helper.
    let initial = resp.jobs.map { makeActiveJob(from: $0, iso: iso) }

    // Second pass: re-fetch jobs whose batch data may be stale.
    return initial.map { job in
        let needsRefresh = job.conclusion == nil
            || job.steps.contains { $0.status == "in_progress" }
        guard needsRefresh else { return job }
        guard
            let freshData = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
            let fresh     = try? JSONDecoder().decode(JobPayload.self, from: freshData),
            fresh.conclusion != nil
        else { return job }
        return makeActiveJob(from: fresh, iso: iso)
    }
}

/// Lower number = higher display priority for sort.
private func statusPriority(_ status: GroupStatus) -> Int {
    switch status {
    case .inProgress: return 0
    case .queued:     return 1
    case .completed:  return 2
    }
}
