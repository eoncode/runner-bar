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

    // MARK: - Compatibility shims

    var groupStatus: String { overallStatus }
    var conclusion: String? { overallConclusion }

    var repo: String? {
        guard let url = htmlUrl ?? runs.first?.htmlUrl,
              let parsed = URL(string: url),
              parsed.pathComponents.count >= 3 else { return nil }
        return "\(parsed.pathComponents[1])/\(parsed.pathComponents[2])"
    }

    var label: String { title }

    var firstJobStartedAt: Date? {
        runs.compactMap(\.createdAt).min()
    }

    var lastJobCompletedAt: Date? {
        runs.compactMap(\.updatedAt).max()
    }

    var createdAt: Date? { firstJobStartedAt }

    var isDimmed: Bool {
        overallConclusion == "skipped" || overallConclusion == "cancelled"
    }

    var jobsTotal: Int { jobs.count }

    var jobsDone: Int { jobs.filter { $0.conclusion != nil }.count }

    var jobProgress: String {
        guard jobsTotal > 0 else { return "" }
        return "\(jobsDone)/\(jobsTotal) jobs"
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

    var currentJobName: String {
        jobs.first(where: { $0.status == "in_progress" })?.name ?? ""
    }

    var isLocalGroup: Bool? {
        let runnerNames = jobs.compactMap(\.runnerName)
        guard !runnerNames.isEmpty else { return nil }
        return runnerNames.allSatisfy { !$0.contains("/") }
    }

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

// MARK: - GroupStatus

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
    // Fetch only active runs (in_progress + queued) so we never miss live
    // workflow runs that sit beyond position 20 in the unfiltered list.
    var runsArray: [[String: Any]] = []
    var seenIDs = Set<Int>()
    for status in ["in_progress", "queued"] {
        let endpoint = scope.contains("/")
            ? "repos/\(scope)/actions/runs?status=\(status)&per_page=50"
            : "orgs/\(scope)/actions/runs?status=\(status)&per_page=50"
        guard let data = ghAPI(endpoint),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let page = json["workflow_runs"] as? [[String: Any]]
        else { continue }
        for r in page {
            guard let id = r["id"] as? Int, seenIDs.insert(id).inserted else { continue }
            runsArray.append(r)
        }
    }
    guard !runsArray.isEmpty else { return [] }
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
    let groups = order.compactMap { sha -> ActionGroup? in
        guard let runs = grouped[sha], let first = runs.first else { return nil }
        return ActionGroup(
            id: sha,
            title: first.name ?? first.event ?? sha,
            runs: runs,
            headBranch: first.headBranch,
            htmlUrl: first.htmlUrl
        )
    }
    log("fetchActionGroups › \(groups.count) group(s) for \(scope)")
    return groups
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
