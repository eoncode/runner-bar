// WorkflowActionGroup.swift
// RunnerBarCore
import Foundation

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

/// Lightweight reference to a single workflow run inside a `WorkflowActionGroup`.
///
/// Holds only the data needed for display and job fetching — deliberately
/// minimal so the full job list lives on the parent `WorkflowActionGroup` instead.
public struct WorkflowRunRef: Identifiable, Sendable {
    /// The unique GitHub run ID.
    public let id: Int
    /// Workflow file name, e.g. `"SonarQube"`, `"vitest"`.
    public let name: String
    /// Current run status string as returned by the API (e.g. `"in_progress"`, `"completed"`).
    public let status: String
    /// Run conclusion once completed (e.g. `"success"`, `"failure"`), or `nil` while running.
    public let conclusion: String?
    /// URL to the run detail page on github.com.
    public let htmlUrl: String?

    /// Creates a new `WorkflowRunRef`.
    /// - Parameters:
    ///   - id: The unique GitHub run ID.
    ///   - name: Workflow file name.
    ///   - status: Current run status string.
    ///   - conclusion: Run conclusion string, or `nil` while running.
    ///   - htmlUrl: URL to the run detail page.
    public init(id: Int, name: String, status: String, conclusion: String?, htmlUrl: String?) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.htmlUrl = htmlUrl
    }
}

// MARK: - WorkflowActionGroup

/// Represents one **commit / PR trigger**: all GitHub Actions workflow runs
/// that share the same `head_sha`. Mirrors ci-dash.py’s “Group” concept from
/// `group_runs()` + `enrich_group()`.
///
/// Hierarchy: `WorkflowActionGroup` → jobs (flat across all sibling runs) → `JobStep` → log.
/// `ActionDetailView` drills into the flat job list; `JobDetailView`/`StepLogView`
/// are reused unchanged below that.
public struct WorkflowActionGroup: Identifiable, Equatable, Sendable {
    /// The git commit SHA that triggered this group of runs.
    public let headSha: String
    /// Short display label: `"#1270"` for PRs, `"d6281b"` (sha[:7]) for push events.
    public let label: String
    /// Commit or PR message first line, truncated to 40 characters.
    public let title: String
    /// The branch this group was triggered on.
    public let headBranch: String?
    /// The `owner/repo` scope string for this group.
    public let repo: String

    /// All sibling workflow runs sharing this `head_sha`.
    public var runs: [WorkflowRunRef]

    /// Stable unique key: highest run ID in this group.
    ///
    /// Run IDs are unique and monotonically increasing — immune to `head_sha` collisions
    /// caused by scheduled workflows firing on the same commit.
    public var id: String { String(runs.map { $0.id }.max() ?? 0) }

    /// All jobs across every run in this group, fetched and flattened.
    /// This is what `ActionDetailView` renders.
    public var jobs: [ActiveJob]

    /// UTC time of the earliest job `startedAt` across all runs.
    /// Mirrors ci-dash.py’s `first_job_started_at`.
    public var firstJobStartedAt: Date?

    /// UTC time of the latest job `completedAt` across all runs.
    /// Mirrors ci-dash.py’s `last_job_completed_at`.
    public var lastJobCompletedAt: Date?

    /// Fallback creation time from the representative run.
    public var createdAt: Date?

    /// Set to `true` when frozen into `actionGroupCache` after completion.
    public var isDimmed: Bool

    // MARK: Equatable

    /// Identity-based equality: two groups are equal when their stable `id` matches.
    ///
    /// This satisfies the `onChange(of: store.actions)` requirement in `PanelMainView`
    /// without deep-comparing mutable job arrays on every poll.
    public static func == (lhs: WorkflowActionGroup, rhs: WorkflowActionGroup) -> Bool {
        lhs.id == rhs.id
    }

    /// Returns a copy of this group with a replacement jobs array.
    ///
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

    /// Creates a new `WorkflowActionGroup`.
    /// - Parameters:
    ///   - headSha: The git commit SHA.
    ///   - label: Short display label (`"#1270"` or `"d6281b"`).
    ///   - title: Commit/PR message first line, ≤40 chars.
    ///   - headBranch: The triggering branch name.
    ///   - repo: The `owner/repo` scope string.
    ///   - runs: Sibling workflow runs sharing this SHA.
    ///   - jobs: Flattened job list. Defaults to empty.
    ///   - firstJobStartedAt: Earliest job start time across all runs.
    ///   - lastJobCompletedAt: Latest job completion time across all runs.
    ///   - createdAt: Fallback creation time from the representative run.
    ///   - isDimmed: `true` when frozen into the completed cache. Defaults to `false`.
    /// - Note: 11 parameters faithfully model the workflow group payload; splitting would break all call sites. // NOSONAR
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

    // MARK: - Derived properties

    /// Group status derived from run-level statuses and job conclusions.
    ///
    /// - Returns `.completed` when all jobs have a conclusion (even if the run-level
    ///   API status lags behind — mirrors ci-dash.py override).
    /// - Returns `.inProgress` when any run is `"in_progress"`.
    /// - Returns `.queued` when any run is `"queued"` but none is in progress.
    public var groupStatus: GroupStatus {
        if jobsTotal > 0, jobs.filter({ $0.conclusion != nil }).count == jobsTotal {
            return .completed
        }
        if runs.contains(where: { $0.status == "in_progress" }) { return .inProgress }
        if runs.contains(where: { $0.status == "queued" }) { return .queued }
        return .completed
    }

    /// Group conclusion derived preferentially from jobs, falling back to runs.
    ///
    /// ⚠️ WHY WE USE JOBS, NOT RUNS:
    /// The GitHub API can report a run-level conclusion of `"failure"` even when every
    /// individual job succeeded. This happens when a job was retried: the first
    /// attempt creates a run whose conclusion is `"failure"`, but the retry run’s jobs
    /// all show `"success"`. Since we flatten all jobs from all sibling runs, using
    /// job-level conclusions is authoritative.
    ///
    /// Priority order: failure > cancelled > skipped > success.
    ///
    /// Returns `nil` while jobs are still loading (`jobs.isEmpty`) or while any job
    /// has not yet concluded, to prevent a premature FAILED badge.
    public var conclusion: String? {
        // Job-based conclusion (preferred) — use when data is fully loaded.
        if !jobs.isEmpty {
            // Only conclude when every single job has a conclusion.
            guard jobs.allSatisfy({ $0.conclusion != nil }) else { return nil }
            // ⚠️ Do NOT change this to read from runs[].conclusion — run-level API
            // conclusions are stale and can report “failure” even when all jobs pass
            // (e.g. after a retry). This caused the spurious FAILED badge (issue #294).
            if jobs.contains(where: { $0.conclusion == .failure }) { return "failure" }
            if jobs.contains(where: { $0.conclusion == .cancelled }) { return "cancelled" }
            let hasSuccess = jobs.contains(where: { $0.conclusion == .success })
            let allSkippedOrCancelled = jobs.allSatisfy {
                $0.conclusion == .skipped || $0.conclusion == .cancelled
            }
            if !hasSuccess && allSkippedOrCancelled { return "skipped" }
            return "success"
        }
        // Run-based conclusion (fallback when jobs haven’t loaded yet).
        // ⚠️ This path is only reached when jobs is empty (loading state).
        // Once jobs are populated the block above takes over.
        guard runs.allSatisfy({ $0.conclusion != nil }) else { return nil }
        if runs.contains(where: { $0.conclusion == "failure" }) { return "failure" }
        if runs.contains(where: { $0.conclusion == "cancelled" }) { return "cancelled" }
        if runs.contains(where: { $0.conclusion == "skipped" }) { return "skipped" }
        return "success"
    }

    /// Number of jobs with a concluded result across all sibling runs.
    public var jobsDone: Int { jobs.filter { $0.conclusion != nil }.count }

    /// Total job count across all sibling runs.
    public var jobsTotal: Int { jobs.count }

    /// Human-readable job progress fraction, e.g. `"3/5"`. Returns `"—"` while jobs load.
    public var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsDone)/\(jobsTotal)" }

    /// Name of the first in-progress job, or first queued job, or `"—"`.
    public var currentJobName: String {
        if let job = jobs.first(where: { $0.status == .inProgress }) { return job.name }
        if let job = jobs.first(where: { $0.status == .queued }) { return job.name }
        return "—"
    }

    /// Human-readable elapsed duration derived from `firstJobStartedAt` → `lastJobCompletedAt`.
    /// Falls back to `createdAt` when no job timing is available.
    public var elapsed: String {
        if let start = firstJobStartedAt {
            let end = lastJobCompletedAt ?? Date()
            let seconds = max(0, Int(end.timeIntervalSince(start)))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        guard let start = createdAt else { return "00:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Runner type

    /// `true` if at least one job in this group ran on a local (self-hosted) runner.
    /// `false` if all assigned jobs ran on GitHub-hosted runners.
    /// `nil` if no job has been assigned to a runner yet (all still queued).
    ///
    /// Detection: any job with `isLocalRunner == true` → local; any job with
    /// `isLocalRunner == false` → cloud; remaining `nil`s are ignored.
    /// Priority: local wins over cloud (mixed groups show the local icon).
    public var isLocalGroup: Bool? {
        let known = jobs.compactMap { $0.isLocalRunner }
        guard !known.isEmpty else { return nil }
        return known.contains(true)
    }
}
