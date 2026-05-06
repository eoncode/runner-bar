import Foundation

// MARK: - ActionGroup model

/// Groups one or more workflow runs that share a `head_sha` into a single display entry.
struct ActionGroup: Identifiable {
    /// Unique identifier — the `head_sha` of the grouped runs.
    var id: String { headSha }
    /// The git SHA shared by all runs in this group.
    let headSha: String
    /// Short branch/SHA label shown in the popover row.
    let label: String
    /// Workflow title shown in the popover row (first run's name).
    let title: String
    /// The head branch name.
    let headBranch: String
    /// The `owner/repo` scope string.
    let repo: String
    /// All workflow runs in this group.
    let runs: [WorkflowRun]
    /// Jobs across all runs, enriched with live data where available.
    var jobs: [ActiveJob]
    /// When the first job in the group started.
    let firstJobStartedAt: Date?
    /// When the last job in the group completed.
    let lastJobCompletedAt: Date?
    /// When the group's first run was created.
    let createdAt: Date?
    /// `true` when the group is shown as a dimmed historical entry.
    var isDimmed: Bool

    /// Combined status across all runs.
    var groupStatus: GroupStatus {
        let statuses = runs.map { $0.status }
        if statuses.contains("in_progress") { return .inProgress }
        if statuses.contains("queued") { return .queued }
        return .completed
    }

    /// Elapsed time string for the whole group.
    var elapsed: String {
        let start = firstJobStartedAt ?? createdAt ?? Date()
        let end = lastJobCompletedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }

    /// Name of the currently running (or last) job, for display in the popover row.
    var currentJobName: String {
        jobs.first(where: { $0.status == "in_progress" })?.name
            ?? jobs.first(where: { $0.status == "queued" })?.name
            ?? jobs.last?.name
            ?? ""
    }

    /// `X/Y` job-count progress label.
    var jobProgress: String {
        let done = jobs.filter { $0.conclusion != nil }.count
        return "\(done)/\(jobs.count)"
    }

    /// Returns a copy of this group with a replacement jobs array.
    func withJobs(_ newJobs: [ActiveJob]) -> ActionGroup {
        ActionGroup(
            headSha: headSha, label: label, title: title,
            headBranch: headBranch, repo: repo, runs: runs,
            jobs: newJobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt, isDimmed: isDimmed
        )
    }
}

// MARK: - GroupStatus

/// Aggregate lifecycle status for an `ActionGroup`.
enum GroupStatus {
    /// At least one run is currently executing.
    case inProgress
    /// All runs are queued, none are executing.
    case queued
    /// All runs have finished.
    case completed
}

// MARK: - WorkflowRun

/// A single workflow run as returned by the GitHub Actions API.
struct WorkflowRun: Identifiable, Decodable {
    let id: Int
    let name: String?
    let status: String
    let conclusion: String?
    let headSha: String
    let headBranch: String?
    let htmlUrl: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headSha = "head_sha"
        case headBranch = "head_branch"
        case htmlUrl = "html_url"
        case createdAt = "created_at"
    }
}

// MARK: - ActionGroup factory

/// RunnerStore extension providing the `ActionGroup` factory and fetch methods.
extension RunnerStore {
    /// Fetches and groups live workflow runs for `scope` into `ActionGroup` values.
    ///
    /// Fetches both `in_progress` and `queued` runs (per_page=50 each) and merges
    /// them by `head_sha`. Enriches each group's jobs from the cache where available.
    /// Skips scopes whose API calls fail.
    func fetchActionGroups(
        for scope: String,
        cache shaKeyedCache: [String: ActionGroup]
    ) -> [ActionGroup] {
        guard scope.contains("/") else { return [] }

        let decoder = JSONDecoder()
        var allRuns: [WorkflowRun] = []

        // Fetch in_progress runs.
        if let data = ghAPI("repos/\(scope)/actions/runs?per_page=50&status=in_progress"),
           let payload = try? decoder.decode(WorkflowRunsPayload.self, from: data) {
            allRuns.append(contentsOf: payload.workflowRuns)
        }

        // Fetch queued runs and merge, deduplicating by run ID.
        if let data = ghAPI("repos/\(scope)/actions/runs?per_page=50&status=queued"),
           let payload = try? decoder.decode(WorkflowRunsPayload.self, from: data) {
            let existingIDs = Set(allRuns.map { $0.id })
            allRuns.append(contentsOf: payload.workflowRuns.filter { !existingIDs.contains($0.id) })
        }

        guard !allRuns.isEmpty else { return [] }

        let iso = ISO8601DateFormatter()
        var grouped: [String: (runs: [WorkflowRun], jobs: [ActiveJob])] = [:]
        for run in allRuns {
            let sha = run.headSha
            let cachedJobs = shaKeyedCache[sha]?.jobs ?? []
            grouped[sha, default: ([], cachedJobs)].runs.append(run)
        }
        return grouped.compactMap { sha, pair in
            guard !pair.runs.isEmpty else { return nil }
            let firstRun = pair.runs[0]
            let branch = firstRun.headBranch ?? sha.prefix(7).description
            let shortSha = String(sha.prefix(7))
            let label = "\(branch.prefix(8))/\(shortSha)"
            let title = firstRun.name ?? "Workflow"
            let jobs = pair.jobs.isEmpty
                ? fetchJobsForRuns(pair.runs, scope: scope, iso: iso)
                : pair.jobs
            return buildActionGroup(
                sha: sha, runs: pair.runs, jobs: jobs,
                label: label, title: title, headBranch: branch,
                repo: scope, isDimmed: false
            )
        }.sorted { ($0.firstJobStartedAt ?? .distantPast) > ($1.firstJobStartedAt ?? .distantPast) }
    }

    // Builds a single `ActionGroup` from decoded run + job data.
    // swiftlint:disable:next function_parameter_count
    private func buildActionGroup(
        sha: String, runs: [WorkflowRun], jobs: [ActiveJob],
        label: String, title: String, headBranch: String,
        repo: String, isDimmed: Bool
    ) -> ActionGroup {
        let startedDates = jobs.compactMap { $0.startedAt }
        let completedDates = jobs.compactMap { $0.completedAt }
        let iso = ISO8601DateFormatter()
        let createdAt = runs.compactMap { $0.createdAt.flatMap { iso.date(from: $0) } }.min()
        return ActionGroup(
            headSha: sha, label: label, title: title,
            headBranch: headBranch, repo: repo, runs: runs,
            jobs: jobs,
            firstJobStartedAt: startedDates.min(),
            lastJobCompletedAt: completedDates.max(),
            createdAt: createdAt, isDimmed: isDimmed
        )
    }

    /// Fetches jobs for a list of runs, used when the cache has no jobs for a sha.
    private func fetchJobsForRuns(
        _ runs: [WorkflowRun],
        scope: String,
        iso: ISO8601DateFormatter
    ) -> [ActiveJob] {
        runs.flatMap { run -> [ActiveJob] in
            guard let data = ghAPI(
                "repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=30"
            ),
                  let payload = try? JSONDecoder().decode(JobsPayload.self, from: data)
            else { return [] }
            return payload.jobs.map { makeActiveJob(from: $0, iso: iso, isDimmed: false) }
        }
    }
}

// MARK: - Decoding helpers

/// Top-level payload for `GET /repos/{owner}/{repo}/actions/runs`.
struct WorkflowRunsPayload: Decodable {
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

/// Top-level payload for `GET /repos/{owner}/{repo}/actions/runs/{id}/jobs`.
struct JobsPayload: Decodable {
    let jobs: [JobPayload]
}
