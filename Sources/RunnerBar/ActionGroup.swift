// swiftlint:disable all
import Foundation

struct WorkflowRun: Identifiable, Equatable {
    let id: Int
    let status: String
    let conclusion: String?
    let headSha: String
    let createdAt: Date?
    let updatedAt: Date?
    let htmlUrl: String?
    let headBranch: String?
    let event: String?
    let name: String?
    let runNumber: Int
    let jobs: [ActiveJob]
}

struct ActionGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let runs: [WorkflowRun]
    let headBranch: String?
    let htmlUrl: String?
    var jobs: [ActiveJob] { runs.flatMap(\.jobs) }
    var headSha: String { runs.first?.headSha ?? "" }

    // MARK: - Computed status

    var overallStatus: String {
        if runs.contains(where: {
            $0.status == "in_progress" || $0.status == "queued"
        }) { return "in_progress" }
        if runs.contains(where: { $0.conclusion == "failure" }) { return "failure" }
        if runs.allSatisfy({ $0.conclusion == "success" }) { return "success" }
        return runs.first?.status ?? "unknown"
    }
    var overallConclusion: String? {
        if runs.isEmpty { return nil }
        if runs.contains(where: { $0.conclusion == "failure" }) { return "failure" }
        if runs.allSatisfy({ $0.conclusion == "success" }) { return "success" }
        return runs.first?.conclusion
    }

    // MARK: - Compatibility shims (call-site compat with old ActionGroup shape)

    /// Maps to `overallStatus` for sites that still reference `.groupStatus`.
    var groupStatus: String { overallStatus }

    /// Maps to `overallConclusion` for sites that still reference `.conclusion`.
    var conclusion: String? { overallConclusion }

    /// Derived from the first run's HTML URL, e.g. "owner/repo".
    var repo: String? {
        guard let url = htmlUrl ?? runs.first?.htmlUrl,
              let parsed = URL(string: url),
              parsed.pathComponents.count >= 3 else { return nil }
        return "\(parsed.pathComponents[1])/\(parsed.pathComponents[2])"
    }

    /// Human-readable label (same as title for new model).
    var label: String { title }

    /// Earliest job start time across all runs.
    var firstJobStartedAt: Date? {
        runs.compactMap(\.createdAt).min()
    }

    /// Latest job completion time across all runs.
    var lastJobCompletedAt: Date? {
        runs.compactMap(\.updatedAt).max()
    }

    /// Alias for `firstJobStartedAt` where old code used `.createdAt`.
    var createdAt: Date? { firstJobStartedAt }

    /// Whether this group should render dimmed.
    var isDimmed: Bool {
        overallConclusion == "skipped" || overallConclusion == "cancelled"
    }

    /// Total number of jobs across all runs.
    var jobsTotal: Int { jobs.count }

    /// Number of completed jobs (those with a non-nil conclusion) across all runs.
    var jobsDone: Int { jobs.filter { $0.conclusion != nil }.count }

    var jobProgress: String {
        guard jobsTotal > 0 else { return "" }
        return "\(jobsDone)/\(jobsTotal) jobs"
    }

    /// Progress fraction (0.0–1.0) of concluded jobs out of total, used by DonutStatusView.
    var progressFraction: Double {
        guard jobsTotal > 0 else { return 0 }
        return Double(jobsDone) / Double(jobsTotal)
    }

    var elapsed: String {
        let start = runs.compactMap(\.createdAt).min()
        let end   = runs.compactMap(\.updatedAt).max()
        guard let start else { return "" }
        let sec = Int((end ?? Date()).timeIntervalSince(start))
        guard sec >= 0 else { return "0s" }
        return sec >= 60
            ? String(format: "%dm%02ds", sec / 60, sec % 60)
            : "\(sec)s"
    }

    /// Name of the currently running job, for display in the action row trailing area.
    var currentJobName: String {
        jobs.first(where: { $0.status == "in_progress" })?.name ?? ""
    }

    /// True when all runners are local (runner name does not contain "/").
    var isLocalGroup: Bool? {
        let runnerNames = jobs.compactMap(\.runnerName)
        guard !runnerNames.isEmpty else { return nil }
        return runnerNames.allSatisfy { !$0.contains("/") }
    }

    /// Returns a copy of this group with a different jobs array (via rebuilt runs).
    func withJobs(_ newJobs: [ActiveJob]) -> ActionGroup {
        guard let first = runs.first else { return self }
        let rebuilt = WorkflowRun(
            id: first.id,
            status: first.status,
            conclusion: first.conclusion,
            headSha: first.headSha,
            createdAt: first.createdAt,
            updatedAt: first.updatedAt,
            htmlUrl: first.htmlUrl,
            headBranch: first.headBranch,
            event: first.event,
            name: first.name,
            runNumber: first.runNumber,
            jobs: newJobs
        )
        let newRuns = [rebuilt] + runs.dropFirst()
        return ActionGroup(
            id: id,
            title: title,
            runs: newRuns,
            headBranch: headBranch,
            htmlUrl: htmlUrl
        )
    }
}

// MARK: - GroupStatus type alias for legacy call sites

/// Legacy enum used in DonutStatusView / PopoverProgressViews.
/// Maps string-based overallStatus to typed cases.
enum GroupStatus: String, Equatable {
    case inProgress = "in_progress"
    case queued
    case completed
    case failed = "failure"
    case success
    case unknown
}

extension ActionGroup {
    var typedGroupStatus: GroupStatus {
        GroupStatus(rawValue: overallStatus) ?? .unknown
    }
}

// MARK: - Fetch helpers

func fetchActionGroups(
    for scope: String,
    cache: [String: ActionGroup] = [:]
) -> [ActionGroup] {
    guard let data = ghAPI("repos/\(scope)/actions/runs?per_page=20"),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let runsArray = json["workflow_runs"] as? [[String: Any]]
    else { return [] }
    let iso = ISO8601DateFormatter()
    var grouped: [String: [WorkflowRun]] = [:]
    var order:   [String] = []
    for r in runsArray {
        guard let id   = r["id"]       as? Int,
              let sha  = r["head_sha"] as? String,
              let stat = r["status"]   as? String else { continue }
        let branch     = r["head_branch"]  as? String
        let htmlUrl    = r["html_url"]     as? String
        let event      = r["event"]        as? String
        let name       = r["name"]         as? String
        let runNum     = r["run_number"]   as? Int ?? 0
        let created    = (r["created_at"]  as? String).flatMap { iso.date(from: $0) }
        let updated    = (r["updated_at"]  as? String).flatMap { iso.date(from: $0) }
        let conclusion = r["conclusion"]   as? String
        let jobs       = fetchJobsForRun(runID: id, scope: scope, iso: iso)
        let run = WorkflowRun(
            id: id,
            status: stat,
            conclusion: conclusion,
            headSha: sha,
            createdAt: created,
            updatedAt: updated,
            htmlUrl: htmlUrl,
            headBranch: branch,
            event: event,
            name: name,
            runNumber: runNum,
            jobs: jobs
        )
        if grouped[sha] == nil { order.append(sha) }
        grouped[sha, default: []].append(run)
    }
    return order.compactMap { sha -> ActionGroup? in
        guard let runs = grouped[sha], let first = runs.first else { return nil }
        return ActionGroup(
            id: sha,
            title: first.name ?? first.event ?? sha,
            runs: runs,
            headBranch: first.headBranch,
            htmlUrl: first.htmlUrl
        )
    }
}

func fetchJobsForRun(
    runID: Int,
    scope: String,
    iso: ISO8601DateFormatter
) -> [ActiveJob] {
    guard let data = ghAPI(
        "repos/\(scope)/actions/runs/\(runID)/jobs?per_page=30"
    ),
          let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
    else { return [] }
    return resp.jobs.map { payload in
        ActiveJob(
            id: payload.id,
            name: payload.name,
            status: payload.status,
            conclusion: payload.conclusion,
            startedAt: payload.startedAt.flatMap { iso.date(from: $0) },
            createdAt: payload.createdAt.flatMap { iso.date(from: $0) },
            completedAt: payload.completedAt.flatMap { iso.date(from: $0) },
            htmlUrl: payload.htmlUrl,
            isDimmed: false,
            steps: (payload.steps ?? []).map { s in
                JobStep(
                    id: s.number,
                    name: s.name,
                    status: s.status,
                    conclusion: s.conclusion,
                    startedAt: s.startedAt.flatMap { iso.date(from: $0) },
                    completedAt: s.completedAt.flatMap { iso.date(from: $0) }
                )
            },
            runnerName: payload.runnerName
        )
    }
}
