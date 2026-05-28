// WorkflowActionGroup.swift
// RunnerBar
// swiftlint:disable file_length
import Foundation

// swiftlint:disable opening_brace identifier_name missing_docs orphaned_doc_comment type_body_length

// MARK: - GroupStatus
/// Type-safe status for a workflow run group (commit/PR trigger).
/// Mirrors ci-dash.py's group status derivation logic.
public enum GroupStatus {
    /// At least one sibling run is in progress.
    case inProgress
    /// No run is in progress, but at least one is queued.
    case queued
    /// All runs have concluded (or all jobs are done).
    case completed
}

// MARK: - WorkflowRunRef
/// Lightweight reference to a single workflow run inside a WorkflowActionGroup.
/// Holds only the data needed for display and job fetching — deliberately
/// minimal so the full job list lives on the parent WorkflowActionGroup instead.
public struct WorkflowRunRef: Identifiable, Sendable {
    public let id: Int
    public let name: String       // workflow file name, e.g. "SonarQube", "vitest"
    public let status: String
    public let conclusion: String?
    public let htmlUrl: String?
    public init(id: Int, name: String, status: String, conclusion: String?, htmlUrl: String?) {
        self.id = id; self.name = name; self.status = status
        self.conclusion = conclusion; self.htmlUrl = htmlUrl
    }
}

// MARK: - WorkflowActionGroup
/// Represents one **commit / PR trigger**: all GitHub Actions workflow runs
/// that share the same `head_sha`. Mirrors ci-dash.py's "Group" concept from
/// `group_runs()` + `enrich_group()`.
///
/// Hierarchy: WorkflowActionGroup → jobs (flat across all sibling runs) → JobStep → log.
/// `ActionDetailView` drills into the flat job list; `JobDetailView`/`StepLogView`
/// are reused unchanged below that.
public struct WorkflowActionGroup: Identifiable, Equatable, Sendable {
    public let headSha: String        // head_sha — kept as the underlying group identity
    public let label: String          // "#1270" if PR, else "d6281b" (sha[:7])
    public let title: String          // commit/PR message first line (≤40 chars)
    public let headBranch: String?
    public let repo: String           // owner/repo scope

    /// All sibling workflow runs sharing this `head_sha`.
    public var runs: [WorkflowRunRef]

    /// Stable unique key: highest run ID in this group.
    /// Run IDs are unique and monotonically increasing — immune to head_sha collisions
    /// caused by scheduled workflows firing on the same commit.
    public var id: String { String(runs.map { $0.id }.max() ?? 0) }

    /// All jobs across every run in this group, fetched and flattened.
    /// This is what `ActionDetailView` renders.
    public var jobs: [ActiveJob] = []

    /// Timestamps derived from job data, not run-level API fields.
    /// Mirrors ci-dash.py's `first_job_started_at` / `last_job_completed_at`.
    public var firstJobStartedAt: Date?
    public var lastJobCompletedAt: Date?

    /// Fallback creation time from the representative run.
    public var createdAt: Date?

    /// Set to `true` when frozen into `actionGroupCache` after completion.
    public var isDimmed: Bool = false

    // MARK: Equatable
    // Identity-based equality: two groups are equal when their stable `id` matches.
    // This satisfies the `onChange(of: store.actions)` requirement in PanelMainView
    // without deep-comparing mutable job arrays on every poll.
    public static func == (lhs: WorkflowActionGroup, rhs: WorkflowActionGroup) -> Bool {
        lhs.id == rhs.id
    }

    /// Returns a copy of this group with a replacement jobs array.
    /// Used in `RunnerStore` to enrich job data without reconstructing the
    /// full struct at every call site.
    public func withJobs(_ newJobs: [ActiveJob]) -> WorkflowActionGroup {
        WorkflowActionGroup(
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

    public init(
        headSha: String,
        label: String,
        title: String,
        headBranch: String?,
        repo: String,
        runs: [WorkflowRunRef],
        jobs: [ActiveJob] = [],
        firstJobStartedAt: Date? = nil,
        lastJobCompletedAt: Date? = nil,
        createdAt: Date? = nil,
        isDimmed: Bool = false
    ) {
        self.headSha = headSha
        self.label = label
        self.title = title
        self.headBranch = headBranch
        self.repo = repo
        self.runs = runs
        self.jobs = jobs
        self.firstJobStartedAt = firstJobStartedAt
        self.lastJobCompletedAt = lastJobCompletedAt
        self.createdAt = createdAt
        self.isDimmed = isDimmed
    }

    // MARK: - Derived properties (match ci-dash.py enrich_group / status_icon)

    /// Group status: in_progress if any run is running; queued if any queued
    /// but none running; completed otherwise.
    /// Also treats the group as completed if all jobs are done, even if the
    /// run-level API status lags behind (mirrors ci-dash.py override).
    public var groupStatus: GroupStatus {
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
    /// The GitHub API can report a run-level conclusion of "failure" even when every
    /// individual job succeeded. This happens when a job was retried: the first
    /// attempt creates a run whose conclusion is "failure", but the retry run's jobs
    /// all show "success". Since we flatten all jobs from all sibling runs, using
    /// job-level conclusions is authoritative.
    ///
    /// Priority order: failure > cancelled > skipped > success.
    ///
    /// Returns nil while jobs are still loading (jobs.isEmpty) or while any job
    /// has not yet concluded, to prevent a premature FAILED badge.
    public var conclusion: String? {
        // ── Job-based conclusion (preferred) ──────────────────────────────────────────────────────
        // Use job data when available and fully loaded.
        if !jobs.isEmpty {
            // Only conclude when every single job has a conclusion.
            // If even one is nil the run is still in progress — return nil.
            guard jobs.allSatisfy({ $0.conclusion != nil }) else { return nil }
            // All jobs are done. Derive group conclusion from their results.
            // ⚠️ Do NOT change this to read from runs[].conclusion — run-level API
            // conclusions are stale and can report "failure" even when all jobs pass
            // (e.g. after a retry). This caused the spurious FAILED badge (issue #294).
            //
            // ActiveJob.conclusion is typed as JobConclusion? — compare against enum cases,
            // not raw strings. The rawValue of each case matches the GitHub API string exactly.
            if jobs.contains(where: { $0.conclusion == .failure })   { return "failure" }
            if jobs.contains(where: { $0.conclusion == .cancelled }) { return "cancelled" }
            // A skipped job is often conditional and should not downgrade the whole
            // workflow result when other jobs actually succeeded.
            let hasSuccess = jobs.contains(where: { $0.conclusion == .success })
            let allSkippedOrCancelled = jobs.allSatisfy {
                $0.conclusion == .skipped || $0.conclusion == .cancelled
            }
            if !hasSuccess && allSkippedOrCancelled { return "skipped" }
            return "success"
        }
        // ── Run-based conclusion (fallback when jobs haven't loaded yet) ────────────────────
        // ⚠️ This path is only reached when jobs is empty (loading state).
        // Once jobs are populated the block above takes over.
        // Do NOT move the run-based logic back to be the primary path — see above.
        // WorkflowRunRef.conclusion is still a raw String? — keep string comparisons here.
        guard runs.allSatisfy({ $0.conclusion != nil }) else { return nil }
        if runs.contains(where: { $0.conclusion == "failure" })   { return "failure" }
        if runs.contains(where: { $0.conclusion == "cancelled" }) { return "cancelled" }
        if runs.contains(where: { $0.conclusion == "skipped" })   { return "skipped" }
        return "success"
    }

    /// Number of jobs with a concluded result across all sibling runs.
    /// Counts all jobs whose `conclusion` is non-nil, regardless of the specific outcome.
    public var jobsDone: Int  { jobs.filter { $0.conclusion != nil }.count }
    /// Total job count across all sibling runs.
    public var jobsTotal: Int { jobs.count }

    /// Human-readable job progress fraction, e.g. "3/5". Returns "—" while jobs load.
    public var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsDone)/\(jobsTotal)" }

    /// Name of the first in-progress job, or first queued, or "—".
    /// ActiveJob.status is typed as JobStatus — compare against enum cases.
    public var currentJobName: String {
        if let job = jobs.first(where: { $0.status == .inProgress }) { return job.name }
        if let job = jobs.first(where: { $0.status == .queued })     { return job.name }
        return "—"
    }

    /// Elapsed time derived from min(job.startedAt) → max(job.completedAt).
    public var elapsed: String {
        if let start = firstJobStartedAt {
            let end = lastJobCompletedAt ?? Date()
            let sec = Int(end.timeIntervalSince(start))
            guard sec >= 0 else { return "00:00" }
            let mins = sec / 60; let secs = sec % 60
            return String(format: "%02d:%02d", mins, secs)
        }
        guard let start = createdAt else { return "00:00" }
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        let mins = sec / 60; let secs = sec % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Runner type

    /// `true` if at least one job in this group ran on a local (self-hosted) runner.
    /// `false` if all assigned jobs ran on GitHub-hosted runners.
    /// `nil` if no job has been assigned to a runner yet (all still queued).
    ///
    /// Detection: any job with isLocalRunner == true → local; any job with
    /// isLocalRunner == false → cloud; remaining nils are ignored.
    /// Priority: local wins over cloud (mixed groups show the local icon).
    public var isLocalGroup: Bool? {
        let known = jobs.compactMap { $0.isLocalRunner }
        guard !known.isEmpty else { return nil }
        return known.contains(true)
    }
}
// swiftlint:enable opening_brace identifier_name missing_docs orphaned_doc_comment type_body_length
