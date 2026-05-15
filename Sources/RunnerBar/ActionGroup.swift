// swiftlint:disable all
// force-v3
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
    var overallStatus: String {
        if runs.contains(where: { $0.status == "in_progress" || $0.status == "queued" }) { return "in_progress" }
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
    var isDimmed: Bool { overallConclusion == "skipped" || overallConclusion == "cancelled" }
    var jobProgress: String {
        let total = jobs.count; guard total > 0 else { return "" }
        let done  = jobs.filter { $0.conclusion != nil }.count
        return "\(done)/\(total) jobs"
    }
    var elapsed: String {
        let start = runs.compactMap(\.createdAt).min()
        let end   = runs.compactMap(\.updatedAt).max()
        guard let start else { return "" }
        let sec = Int((end ?? Date()).timeIntervalSince(start))
        guard sec >= 0 else { return "0s" }
        return sec >= 60 ? String(format: "%dm%02ds", sec / 60, sec % 60) : "\(sec)s"
    }
}

func fetchActionGroups(for scope: String, cache: [String: ActionGroup] = [:]) -> [ActionGroup] {
    guard let data = ghAPI("repos/\(scope)/actions/runs?per_page=20"),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let runsArray = json["workflow_runs"] as? [[String: Any]] else { return [] }
    let iso = ISO8601DateFormatter()
    var grouped: [String: [WorkflowRun]] = [:]
    var order:   [String] = []
    for r in runsArray {
        guard let id   = r["id"]         as? Int,
              let sha  = r["head_sha"]   as? String,
              let stat = r["status"]     as? String else { continue }
        let branch  = r["head_branch"]  as? String
        let htmlUrl = r["html_url"]     as? String
        let event   = r["event"]        as? String
        let name    = r["name"]         as? String
        let runNum  = r["run_number"]   as? Int ?? 0
        let created = (r["created_at"]  as? String).flatMap { iso.date(from: $0) }
        let updated = (r["updated_at"]  as? String).flatMap { iso.date(from: $0) }
        let conclusion = r["conclusion"] as? String
        let jobs = fetchJobs(runID: id, scope: scope)
        let run  = WorkflowRun(id: id, status: stat, conclusion: conclusion,
                               headSha: sha, createdAt: created, updatedAt: updated,
                               htmlUrl: htmlUrl, headBranch: branch, event: event,
                               name: name, runNumber: runNum, jobs: jobs)
        if grouped[sha] == nil { order.append(sha) }
        grouped[sha, default: []].append(run)
    }
    return order.compactMap { sha -> ActionGroup? in
        guard let runs = grouped[sha], let first = runs.first else { return nil }
        return ActionGroup(id: sha,
                           title: first.name ?? first.event ?? sha,
                           runs: runs,
                           headBranch: first.headBranch,
                           htmlUrl: first.htmlUrl)
    }
}

func fetchJobs(runID: Int, scope: String) -> [ActiveJob] {
    guard let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=30"),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let jobsArr = json["jobs"] as? [[String: Any]] else { return [] }
    let iso = ISO8601DateFormatter()
    return jobsArr.compactMap { j -> ActiveJob? in
        guard let id     = j["id"]         as? Int,
              let name   = j["name"]       as? String,
              let status = j["status"]     as? String else { return nil }
        let conclusion  = j["conclusion"]  as? String
        let htmlUrl     = j["html_url"]    as? String
        let runnerName  = j["runner_name"] as? String
        let startedAt   = (j["started_at"]   as? String).flatMap { iso.date(from: $0) }
        let completedAt = (j["completed_at"] as? String).flatMap { iso.date(from: $0) }
        let stepsRaw    = j["steps"] as? [[String: Any]] ?? []
        let steps: [JobStep] = stepsRaw.compactMap { s in
            guard let num  = s["number"] as? Int,
                  let stat = s["status"] as? String else { return nil }
            return JobStep(id: num, name: s["name"] as? String, status: stat,
                           conclusion: s["conclusion"] as? String,
                           startedAt:   (s["started_at"]   as? String).flatMap { iso.date(from: $0) },
                           completedAt: (s["completed_at"] as? String).flatMap { iso.date(from: $0) })
        }
        return ActiveJob(id: id, name: name, status: status, conclusion: conclusion,
                         htmlUrl: htmlUrl, runnerName: runnerName,
                         startedAt: startedAt, completedAt: completedAt, steps: steps)
    }
}

func reRunJob(jobID: Int, repoSlug: String) -> Bool {
    ghAPI("repos/\(repoSlug)/actions/jobs/\(jobID)/rerun", method: "POST") != nil
}

func reRunFailedJobs(runID: Int, repoSlug: String) -> Bool {
    ghAPI("repos/\(repoSlug)/actions/runs/\(runID)/rerun-failed-jobs", method: "POST") != nil
}

func cancelRun(runID: Int, scope: String) -> Bool {
    ghAPI("repos/\(scope)/actions/runs/\(runID)/cancel", method: "POST") != nil
}

func fetchJobLog(jobID: Int, scope: String) -> String {
    guard let data = ghAPI("repos/\(scope)/actions/jobs/\(jobID)/logs") else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}
