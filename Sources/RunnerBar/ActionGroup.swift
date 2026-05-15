// swiftlint:disable file_length
import Foundation

// swiftlint:disable opening_brace identifier_name missing_docs orphaned_doc_comment

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
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let htmlUrl: String?
}

// MARK: - ActionGroup
/// Represents one **commit / PR trigger**: all GitHub Actions workflow runs
/// that share the same `head_sha`.
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
    var htmlUrl: String? {
        guard let raw = runs.compactMap({ $0.htmlUrl }).first else { return nil }
        let components = raw.components(separatedBy: "/")
        guard components.count >= 5 else { return raw }
        return components.prefix(5).joined(separator: "/")
    }
    static func == (lhs: ActionGroup, rhs: ActionGroup) -> Bool { lhs.id == rhs.id }
    func withJobs(_ newJobs: [ActiveJob]) -> ActionGroup {
        ActionGroup(
            headSha: headSha, label: label, title: title, headBranch: headBranch,
            repo: repo, runs: runs, jobs: newJobs,
            firstJobStartedAt: firstJobStartedAt, lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt, isDimmed: isDimmed
        )
    }
    var groupStatus: GroupStatus {
        if jobsTotal > 0, jobs.filter({ $0.conclusion != nil }).count == jobsTotal { return .completed }
        if runs.contains(where: { $0.status == "in_progress" }) { return .inProgress }
        if runs.contains(where: { $0.status == "queued" })      { return .queued }
        return .completed
    }
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
    var jobsDone: Int  { jobs.filter { $0.conclusion != nil }.count }
    var jobsTotal: Int { jobs.count }
    var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsDone)/\(jobsTotal)" }
    var currentJobName: String {
        if let job = jobs.first(where: { $0.status == "in_progress" }) { return job.name }
        if let job = jobs.first(where: { $0.status == "queued" })      { return job.name }
        return "—"
    }
    var elapsed: String {
        if let start = firstJobStartedAt {
            let end = lastJobCompletedAt ?? Date()
            let sec = Int(end.timeIntervalSince(start))
            guard sec >= 0 else { return "00:00" }
            return String(format: "%02d:%02d", sec / 60, sec % 60)
        }
        guard let start = createdAt else { return "00:00" }
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
    var isLocalGroup: Bool? {
        let known = jobs.compactMap { $0.isLocalRunner }
        guard !known.isEmpty else { return nil }
        return known.contains(true)
    }
}

// MARK: - Codable helpers
private struct ActionRunsResponse: Codable {
    let workflowRuns: [RunPayload]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}
private struct RunPayload: Codable {
    let id: Int; let name: String; let status: String; let conclusion: String?
    let headBranch: String?; let headSha: String; let displayTitle: String?
    let createdAt: String?; let updatedAt: String?; let htmlUrl: String?
    let headCommit: HeadCommit?; let pullRequests: [PRRef]?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headBranch = "head_branch"; case headSha = "head_sha"
        case displayTitle = "display_title"; case createdAt = "created_at"
        case updatedAt = "updated_at"; case htmlUrl = "html_url"
        case headCommit = "head_commit"; case pullRequests = "pull_requests"
    }
}
private struct HeadCommit: Codable { let message: String }
private struct PRRef: Codable { let number: Int }

private func prLabel(from run: RunPayload) -> String {
    if let pr = run.pullRequests?.first { return "#\(pr.number)" }
    if let branch = run.headBranch,
       let range = branch.range(of: #"/(\d+)/"#, options: .regularExpression) {
        return "#\(branch[range].filter { $0.isNumber })"
    }
    return String(run.headSha.prefix(7))
}

// swiftlint:disable:next function_body_length cyclomatic_complexity
func fetchActionGroups(for scope: String, cache: [String: ActionGroup] = [:]) -> [ActionGroup] {
    guard scope.contains("/") else { log("fetchActionGroups › skipping org scope \(scope)"); return [] }
    var runPayloads: [RunPayload] = []; var seenIDs = Set<Int>()
    for status in ["in_progress", "queued"] {
        let endpoint = "repos/\(scope)/actions/runs?status=\(status)&per_page=50"
        guard let data = ghAPI(endpoint),
              let resp = try? JSONDecoder().decode(ActionRunsResponse.self, from: data) else { continue }
        for run in resp.workflowRuns where seenIDs.insert(run.id).inserted { runPayloads.append(run) }
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
        let label = prLabel(from: rep)
        let rawTitle = rep.displayTitle ?? rep.headCommit
            .map { String($0.message.components(separatedBy: "\n").first ?? "") }
            ?? String(sha.prefix(7))
        let title = String(rawTitle.prefix(40))
        let runs: [WorkflowRunRef] = shaRuns.map {
            WorkflowRunRef(id: $0.id, name: $0.name, status: $0.status,
                           conclusion: $0.conclusion, htmlUrl: $0.htmlUrl)
        }
        let allJobs: [ActiveJob]
        if let cached = cache[sha], !cached.jobs.isEmpty,
           cached.jobs.allSatisfy({ $0.conclusion != nil }) &&
           !cached.jobs.contains(where: { $0.steps.contains { $0.status == "in_progress" } }) {
            allJobs = cached.jobs
        } else {
            var fetched: [ActiveJob] = []; var seenJobIDs = Set<Int>()
            for runID in shaRuns.map({ $0.id }) {
                for job in fetchJobsForRun(runID, scope: scope)
                where seenJobIDs.insert(job.id).inserted { fetched.append(job) }
            }
            fetched.sort { $0.id < $1.id }; allJobs = fetched
        }
        let starts = allJobs.compactMap { $0.startedAt }
        let ends   = allJobs.compactMap { $0.completedAt }
        return ActionGroup(
            headSha: sha, label: label, title: title, headBranch: rep.headBranch,
            repo: scope, runs: runs, jobs: allJobs,
            firstJobStartedAt: starts.min(), lastJobCompletedAt: ends.max(),
            createdAt: rep.createdAt.flatMap { iso8601.date(from: $0) }
        )
    }
    groups.sort {
        let lp = statusPriority($0.groupStatus), rp = statusPriority($1.groupStatus)
        if lp != rp { return lp < rp }
        return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
    }
    log("fetchActionGroups › \(groups.count) group(s) for \(scope)")
    return groups
}

func makeActiveJob(from jobPayload: JobPayload,
                   iso: ISO8601DateFormatter,
                   isDimmed: Bool = false) -> ActiveJob {
    let steps: [JobStep] = (jobPayload.steps ?? []).map { step in
        JobStep(id: step.number, name: step.name, status: step.status,
                conclusion: step.conclusion,
                startedAt: step.startedAt.flatMap { iso.date(from: $0) },
                completedAt: step.completedAt.flatMap { iso.date(from: $0) })
    }
    return ActiveJob(
        id: jobPayload.id, name: jobPayload.name, status: jobPayload.status,
        conclusion: jobPayload.conclusion,
        startedAt: jobPayload.startedAt.flatMap { iso.date(from: $0) },
        createdAt: jobPayload.createdAt.flatMap { iso.date(from: $0) },
        completedAt: jobPayload.completedAt.flatMap { iso.date(from: $0) },
        htmlUrl: jobPayload.htmlUrl, isDimmed: isDimmed, steps: steps,
        runnerName: jobPayload.runnerName
    )
}

private func fetchJobsForRun(_ runID: Int, scope: String) -> [ActiveJob] {
    guard let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
          let resp = try? JSONDecoder().decode(JobsResponse.self, from: data) else { return [] }
    let initial = resp.jobs.map { makeActiveJob(from: $0, iso: iso8601) }
    var result = initial; var refreshCount = 0
    for idx in result.indices {
        let job = result[idx]
        let needsRefresh = job.conclusion == nil || job.steps.contains { $0.status == "in_progress" }
        guard needsRefresh, refreshCount < 3 else { continue }
        refreshCount += 1
        guard let freshData = ghAPI("repos/\(scope)/actions/jobs/\(job.id)"),
              let fresh = try? JSONDecoder().decode(JobPayload.self, from: freshData) else { continue }
        let freshJob = makeActiveJob(from: fresh, iso: iso8601)
        if fresh.conclusion != nil { result[idx] = freshJob; continue }
        let betterSteps = !freshJob.steps.isEmpty && !freshJob.steps.contains { $0.status == "in_progress" }
        if betterSteps {
            result[idx] = ActiveJob(
                id: job.id, name: job.name, status: job.status, conclusion: job.conclusion,
                startedAt: freshJob.startedAt ?? job.startedAt,
                createdAt: freshJob.createdAt ?? job.createdAt,
                completedAt: freshJob.completedAt ?? job.completedAt,
                htmlUrl: job.htmlUrl, isDimmed: job.isDimmed, steps: freshJob.steps,
                runnerName: freshJob.runnerName ?? job.runnerName
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
// swiftlint:enable file_length
