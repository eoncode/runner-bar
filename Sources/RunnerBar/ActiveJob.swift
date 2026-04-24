import Foundation

// MARK: - Model

struct ActiveJob: Identifiable {
    let id: Int
    let name: String
    let status: String       // "queued", "in_progress", "completed"
    let conclusion: String?  // "success", "failure", "cancelled", nil when truly active
    let startedAt: Date?
    let createdAt: Date?

    /// Elapsed time since the job started (or was created if still queued).
    var elapsed: String {
        guard let start = startedAt ?? createdAt else { return "—" }
        let sec = Int(Date().timeIntervalSince(start))
        guard sec >= 0 else { return "—" }
        let m = sec / 60; let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Fetch

/// Fetches in_progress AND queued workflow runs for `scope`, collects their
/// jobs, filters to only truly active ones (conclusion == nil), deduplicates,
/// and sorts: in_progress → queued.
func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    let iso = ISO8601DateFormatter()
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    // Build the correct API path for repo vs org scope.
    // Org-level endpoint: /orgs/{org}/actions/runs
    // Repo-level endpoint: /repos/{owner}/{repo}/actions/runs
    func runsPath(status: String) -> String {
        if scope.contains("/") {
            return "/repos/\(scope)/actions/runs?status=\(status)&per_page=50"
        } else {
            return "/orgs/\(scope)/actions/runs?status=\(status)&per_page=50"
        }
    }

    // Fetch both in_progress and queued runs so we catch everything active.
    for status in ["in_progress", "queued"] {
        let path = runsPath(status: status)
        log("fetchActiveJobs › fetching \(status) runs: \(path)")
        let json = shell("/opt/homebrew/bin/gh api \(path)")
        guard
            let data = json.data(using: .utf8),
            let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        else {
            log("fetchActiveJobs › failed to decode \(status) runs for \(scope)")
            continue
        }
        log("fetchActiveJobs › \(resp.workflowRuns.count) \(status) run(s)")
        for run in resp.workflowRuns {
            if seenRunIDs.insert(run.id).inserted {
                runIDs.append(run.id)
            }
        }
    }

    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()

    for runID in runIDs {
        let path = "/repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"
        let json = shell("/opt/homebrew/bin/gh api \(path)")
        guard
            let data = json.data(using: .utf8),
            let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else {
            log("fetchActiveJobs › failed to decode jobs for run \(runID)")
            continue
        }
        for j in resp.jobs {
            guard seenJobIDs.insert(j.id).inserted else { continue }
            // KEY FIX: skip jobs that already have a conclusion — they are done.
            // Without this filter the section fills with completed jobs and the
            // Active Jobs section never shows truly in-flight work.
            guard j.conclusion == nil else { continue }
            jobs.append(ActiveJob(
                id:         j.id,
                name:       j.name,
                status:     j.status,
                conclusion: j.conclusion,
                startedAt:  j.startedAt.flatMap  { iso.date(from: $0) },
                createdAt:  j.createdAt.flatMap  { iso.date(from: $0) }
            ))
        }
    }

    log("fetchActiveJobs › \(jobs.count) truly active job(s) for \(scope)")
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
    let createdAt: String?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case startedAt = "started_at"
        case createdAt = "created_at"
    }
}
