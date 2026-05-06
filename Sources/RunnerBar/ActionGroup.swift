import Foundation

// MARK: - ActionGroup model

/// A logical grouping of GitHub Actions workflow runs sharing the same `head_sha`.
///
/// Aggregates multiple `WorkflowRun` entries into a single popover row, showing
/// the aggregate status, timing, and individual jobs for that commit.
struct ActionGroup: Identifiable, Equatable {
    // MARK: Stored properties
    /// Unique identifier — the `head_sha` of the grouped runs.
    let id: String
    /// Commit SHA all grouped runs share.
    let headSha: String
    /// Short human-readable label (e.g. branch name or PR title).
    let label: String
    /// Most recent workflow run title in the group.
    let title: String
    /// Branch name associated with the grouped runs.
    let headBranch: String
    /// `owner/repo` string for the repository.
    let repo: String
    /// All workflow runs in the group.
    let runs: [WorkflowRun]
    /// All jobs across all runs in the group.
    let jobs: [ActiveJob]
    /// Earliest job start time in the group.
    let firstJobStartedAt: Date?
    /// Latest job completion time in the group, or nil if still running.
    let lastJobCompletedAt: Date?
    /// Workflow-run creation time (used when job timestamps are unavailable).
    let createdAt: Date?
    /// When true, this group is shown dimmed (recently completed).
    var isDimmed: Bool

    // MARK: Computed
    /// Aggregate status across all runs in the group.
    var groupStatus: AggregateStatus {
        if runs.contains(where: { $0.status == "in_progress" }) { return .inProgress }
        if runs.contains(where: { $0.status == "queued" || $0.status == "waiting" }) { return .queued }
        return .completed
    }

    /// Overall conclusion collapsed from all run conclusions.
    var overallConclusion: String? {
        let conclusions = runs.compactMap { $0.conclusion }
        if conclusions.contains("failure") { return "failure" }
        if conclusions.contains("cancelled") { return "cancelled" }
        if conclusions.contains("skipped") { return "skipped" }
        if conclusions.allSatisfy({ $0 == "success" }) { return "success" }
        return conclusions.first
    }

    /// Returns a copy of the group with its jobs replaced by `newJobs`.
    func withJobs(_ newJobs: [ActiveJob]) -> ActionGroup {
        ActionGroup(
            headSha: headSha, label: label, title: title, headBranch: headBranch,
            repo: repo, runs: runs, jobs: newJobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt, isDimmed: isDimmed
        )
    }
}

// MARK: - AggregateStatus

/// The overall run/job status for an `ActionGroup`.
enum AggregateStatus {
    /// At least one run or job is actively executing.
    case inProgress
    /// All runs/jobs are queued or waiting; none are actively executing.
    case queued
    /// All runs/jobs have finished.
    case completed
    /// All runners are online.
    case allOnline
    /// Some runners are offline.
    case someOffline
    /// All runners are offline.
    case allOffline
}

// MARK: - WorkflowRun

/// Thin model for a single GitHub Actions workflow run, as returned by the list-runs API.
struct WorkflowRun: Codable, Identifiable, Equatable {
    /// GitHub run ID.
    let id: Int
    /// Human-readable run title (commit message headline or custom name).
    let name: String?
    /// Current run status (e.g. `in_progress`, `queued`, `completed`).
    let status: String?
    /// Final conclusion once completed (e.g. `success`, `failure`, `cancelled`).
    let conclusion: String?
    /// ISO-8601 timestamp when the run was created.
    let createdAt: String?
    /// Branch the run targets.
    let headBranch: String?
    /// Commit SHA the run targets.
    let headSha: String
    /// URL to the run on GitHub.com.
    let htmlUrl: String?
    /// Commit message headline associated with this run.
    let displayTitle: String?

    /// Maps JSON snake_case keys to Swift camelCase properties.
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case createdAt = "created_at"
        case headBranch = "head_branch"
        case headSha = "head_sha"
        case htmlUrl = "html_url"
        case displayTitle = "display_title"
    }
}

// MARK: - RunsResponse

/// Top-level envelope for the GitHub list-workflow-runs API response.
struct RunsResponse: Codable {
    /// Paginated array of workflow runs.
    let workflowRuns: [WorkflowRun]
    /// Maps `workflow_runs` JSON key.
    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

// MARK: - ActionGroup factory

extension RunnerStore {
    /// Fetches and groups live workflow runs for `scope` into `ActionGroup` values.
    ///
    /// Groups runs by `head_sha`. Enriches each group's jobs from the cache where available.
    /// Skips scopes whose API call fails.
    func fetchActionGroups(
        for scope: String,
        cache shaKeyedCache: [String: ActionGroup]
    ) -> [ActionGroup] {
        guard let data = ghAPI("repos/\(scope)/actions/runs?per_page=20&status=in_progress"),
              let decoded = try? JSONDecoder().decode(RunsResponse.self, from: data)
        else { return [] }
        let grouped = Dictionary(grouping: decoded.workflowRuns, by: { $0.headSha })
        return grouped.compactMap { sha, runs -> ActionGroup? in
            guard let first = runs.first else { return nil }
            let cached = shaKeyedCache[sha]
            let jobs = cached?.jobs ?? fetchJobsForRuns(runs, scope: scope)
            return buildActionGroup(
                sha: sha, runs: runs, jobs: jobs,
                label: first.headBranch ?? sha, title: first.displayTitle ?? first.name ?? sha,
                headBranch: first.headBranch ?? "", repo: scope, isDimmed: false
            )
        }.sorted { ($0.firstJobStartedAt ?? .distantPast) > ($1.firstJobStartedAt ?? .distantPast) }
    }

    /// Builds a single `ActionGroup` from decoded run + job data.
    private func buildActionGroup(
        sha: String, runs: [WorkflowRun], jobs: [ActiveJob],
        label: String, title: String, headBranch: String,
        repo: String, isDimmed: Bool
    ) -> ActionGroup {
        let startedDates = jobs.compactMap { $0.startedAt }
        let completedDates = jobs.compactMap { $0.completedAt }
        let iso = ISO8601DateFormatter()
        let runCreatedAt = runs.compactMap {
            $0.createdAt.flatMap { iso.date(from: $0) }
        }.min()
        return ActionGroup(
            headSha: sha, label: label, title: title, headBranch: headBranch,
            repo: repo, runs: runs, jobs: jobs,
            firstJobStartedAt: startedDates.min(),
            lastJobCompletedAt: completedDates.max(),
            createdAt: runCreatedAt, isDimmed: isDimmed
        )
    }

    /// Fetches all jobs for an array of workflow runs in `scope`.
    private func fetchJobsForRuns(_ runs: [WorkflowRun], scope: String) -> [ActiveJob] {
        let iso = ISO8601DateFormatter()
        return runs.flatMap { run -> [ActiveJob] in
            guard let data = ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs"),
                  let payload = try? JSONDecoder().decode(JobsPayload.self, from: data)
            else { return [] }
            return payload.jobs.map { makeActiveJob(from: $0, iso: iso, isDimmed: false) }
        }
    }

    /// Looks up the `owner/repo` scope from a job's `html_url`.
    func scopeFromHtmlUrl(_ url: String) -> String? {
        let parts = url.split(separator: "/")
        guard parts.count >= 4 else { return nil }
        return "\(parts[1])/\(parts[2])"
    }
}
