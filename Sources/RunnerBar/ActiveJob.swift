import Foundation

// MARK: - Model

struct ActiveJob: Identifiable {
    let id: Int
    let name: String
    let status: String       // "queued", "in_progress", "completed"
    let conclusion: String?  // "success", "failure", "cancelled", nil
    let startedAt: Date?

    /// Elapsed time since the job started, formatted as MM:SS.
    var elapsed: String {
        guard let start = startedAt else { return "—" }
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "—" }
        let m = sec / 60; let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Fetch

/// Fetches active (in_progress + queued) workflow runs for `scope`, then
/// collects all their jobs. Sorted: in_progress first, queued second, done last.
func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    let repoSlug = scope.contains("/") ? scope : nil

    // Only repo-scoped runs are supported by the jobs endpoint
    guard let repo = repoSlug else {
        log("fetchActiveJobs › org-level runs not supported, skipping \(scope)")
        return []
    }

    let runsPath = "/repos/\(repo)/actions/runs?status=in_progress&per_page=10"
    log("fetchActiveJobs › fetching runs: \(runsPath)")
    let runsJSON = shell("/opt/homebrew/bin/gh api \(runsPath)")

    guard
        let runsData = runsJSON.data(using: .utf8),
        let runsResp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: runsData)
    else {
        log("fetchActiveJobs › failed to decode runs for \(scope)")
        return []
    }

    log("fetchActiveJobs › \(runsResp.workflowRuns.count) active run(s) for \(scope)")

    let iso = ISO8601DateFormatter()
    var jobs: [ActiveJob] = []

    for run in runsResp.workflowRuns {
        let jobsPath = "/repos/\(repo)/actions/runs/\(run.id)/jobs?per_page=30"
        let jobsJSON = shell("/opt/homebrew/bin/gh api \(jobsPath)")
        guard
            let jobsData = jobsJSON.data(using: .utf8),
            let jobsResp = try? JSONDecoder().decode(JobsResponse.self, from: jobsData)
        else {
            log("fetchActiveJobs › failed to decode jobs for run \(run.id)")
            continue
        }
        for j in jobsResp.jobs {
            jobs.append(ActiveJob(
                id:         j.id,
                name:       j.name,
                status:     j.status,
                conclusion: j.conclusion,
                startedAt:  j.startedAt.flatMap { iso.date(from: $0) }
            ))
        }
    }

    log("fetchActiveJobs › \(jobs.count) total job(s) for \(scope)")

    // in_progress first, queued second, completed last
    return jobs.sorted { rank($0) < rank($1) }
}

private func rank(_ job: ActiveJob) -> Int {
    switch job.status {
    case "in_progress": return 0
    case "queued":      return 1
    default:            return 2
    }
}

// MARK: - Codable helpers

private struct WorkflowRunsResponse: Codable {
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}
private struct WorkflowRun: Codable { let id: Int }
private struct JobsResponse: Codable { let jobs: [JobPayload] }
private struct JobPayload: Codable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case startedAt = "started_at"
    }
}
