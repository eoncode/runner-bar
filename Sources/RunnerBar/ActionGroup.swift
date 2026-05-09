import Foundation
// swiftlint:disable opening_brace identifier_name missing_docs orphaned_doc_comment

// MARK: - GroupStatus

enum GroupStatus {
    case inProgress
    case queued
    case completed
}

// MARK: - WorkflowRunRef

struct WorkflowRunRef: Identifiable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let htmlUrl: String?
}

// MARK: - ActionGroup

struct ActionGroup: Identifiable, Equatable {
    let headSha: String
    let label: String
    let title: String
    let headBranch: String?
    let repo: String

    var runs: [WorkflowRunRef]
    var id: String { String(runs.map { $0.id }.max() ?? 0) }
    var jobs: [ActiveJob] = []
    var firstJobStartedAt: Date?
    var lastJobCompletedAt: Date?
    var createdAt: Date?
    var isDimmed: Bool = false

    func withJobs(_ newJobs: [ActiveJob]) -> ActionGroup {
        ActionGroup(
            headSha: headSha, label: label, title: title, headBranch: headBranch,
            repo: repo, runs: runs, jobs: newJobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt, isDimmed: isDimmed
        )
    }

    // MARK: - Derived properties

    var groupStatus: GroupStatus {
        if jobsTotal > 0,
           jobs.filter({ $0.conclusion != nil }).count == jobsTotal { return .completed }
        if runs.contains(where: { $0.status == "in_progress" }) { return .inProgress }
        if runs.contains(where: { $0.status == "queued" }) { return .queued }
        return .completed
    }

    var conclusion: String? {
        guard runs.allSatisfy({ $0.conclusion != nil }) else { return nil }
        if runs.contains(where: { $0.conclusion == "failure" })   { return "failure" }
        if runs.contains(where: { $0.conclusion == "cancelled" }) { return "cancelled" }
        if runs.contains(where: { $0.conclusion == "skipped" })   { return "skipped" }
        return "success"
    }

    var jobsDone: Int {
        jobs.filter { $0.conclusion == "success" || $0.conclusion == "skipped" }.count
    }

    var jobsTotal: Int { jobs.count }

    var jobProgress: String { jobs.isEmpty ? "\u{2014}" : "\(jobsDone)/\(jobsTotal)" }

    var currentJobName: String {
        if let j = jobs.first(where: { $0.status == "in_progress" }) { return j.name }
        if let j = jobs.first(where: { $0.status == "queued" })      { return j.name }
        return "\u{2014}"
    }

    var startedAgo: String {
        guard let ref = firstJobStartedAt ?? createdAt else { return "\u{2014}" }
        return RelativeTimeFormatter.string(from: ref)
    }

    var elapsed: String {
        if let start = firstJobStartedAt {
            let end = lastJobCompletedAt ?? Date()
            let sec = Int(end.timeIntervalSince(start))
            guard sec >= 0 else { return "00:00" }
            let m = sec / 60; let s = sec % 60
            return String(format: "%02d:%02d", m, s)
        }
        guard let start = createdAt else { return "00:00" }
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        let m = sec / 60; let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var progressFraction: Double? {
        switch groupStatus {
        case .queued:    return nil
        case .completed: return 1.0
        case .inProgress:
            guard jobsTotal > 0 else { return nil }
            return Double(jobsDone) / Double(jobsTotal)
        }
    }

    // MARK: - Equatable
    static func == (lhs: ActionGroup, rhs: ActionGroup) -> Bool {
        lhs.id == rhs.id
            && lhs.isDimmed == rhs.isDimmed
            && lhs.jobs == rhs.jobs
            && lhs.runs.map({ $0.id }) == rhs.runs.map({ $0.id })
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

// swiftlint:disable:next function_body_length cyclomatic_complexity
func fetchActionGroups(for scope: String, cache: [String: ActionGroup] = [:]) -> [ActionGroup] {
    guard scope.contains("/") else {
        log("fetchActionGroups \u{203A} skipping org scope \(scope)")
        return []
    }

    let iso = ISO8601DateFormatter()
    var runPayloads: [RunPayload] = []
    var seenIDs = Set<Int>()

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

    var bySha: [String: [RunPayload]] = [:]
    for run in runPayloads {
        bySha[run.headSha, default: []].append(run)
    }

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

    log("fetchActionGroups \u{203A} \(groups.count) group(s) for \(scope)")
    return groups
}

// MARK: - Private helpers

func makeActiveJob(from j: JobPayload, iso: ISO8601DateFormatter,
                   isDimmed: Bool = false) -> ActiveJob {
    let steps: [JobStep] = (j.steps ?? []).enumerated().map { idx, s in
        JobStep(
            id: idx + 1,
            name: s.name,
            status: s.status,
            conclusion: s.conclusion,
            startedAt: s.startedAt,
            completedAt: s.completedAt
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

private func statusPriority(_ status: GroupStatus) -> Int {
    switch status {
    case .inProgress: return 0
    case .queued:     return 1
    case .completed:  return 2
    }
}
// swiftlint:enable opening_brace identifier_name missing_docs orphaned_doc_comment
