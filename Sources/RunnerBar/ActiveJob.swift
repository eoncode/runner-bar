import Foundation

// MARK: - Model

struct ActiveJob: Identifiable {
    let id: Int
    let name: String
    let status: String       // "queued", "in_progress", "completed"
    let conclusion: String?  // nil when truly active
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

// MARK: - gh API (no shell — avoids & metacharacter splitting)

/// Calls `gh api <endpoint>` directly via Process, bypassing /bin/zsh.
/// This mirrors Python's subprocess.run(['gh', 'api', url]) and avoids
/// zsh treating & in query strings as a background operator.
private func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    let gh = "/opt/homebrew/bin/gh"
    guard FileManager.default.isExecutableFile(atPath: gh) else {
        log("ghAPI › gh not found at \(gh)")
        return nil
    }

    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: gh)
    task.arguments     = ["api", endpoint]
    task.standardOutput = pipe
    task.standardError  = Pipe() // discard stderr

    var outputData = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock(); outputData.append(chunk); lock.unlock()
    }

    do { try task.run() } catch {
        log("ghAPI › launch error for \(endpoint): \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning {
        if Date() > deadline {
            log("ghAPI › timeout for \(endpoint)")
            task.terminate(); break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }

    log("ghAPI › \(endpoint) → \(outputData.count) bytes, exit \(task.terminationStatus)")
    return outputData.isEmpty ? nil : outputData
}

// MARK: - Fetch

func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    let iso = ISO8601DateFormatter()
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    func runsEndpoint(status: String) -> String {
        if scope.contains("/") {
            return "repos/\(scope)/actions/runs?status=\(status)&per_page=50"
        } else {
            return "orgs/\(scope)/actions/runs?status=\(status)&per_page=50"
        }
    }

    for status in ["in_progress", "queued"] {
        let endpoint = runsEndpoint(status: status)
        log("fetchActiveJobs › \(endpoint)")
        guard
            let data = ghAPI(endpoint),
            let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        else {
            log("fetchActiveJobs › decode failed for \(status) runs (scope: \(scope))")
            continue
        }
        log("fetchActiveJobs › \(resp.workflowRuns.count) \(status) run(s)")
        for run in resp.workflowRuns {
            if seenRunIDs.insert(run.id).inserted { runIDs.append(run.id) }
        }
    }

    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()

    for runID in runIDs {
        // Job-level endpoint is always repo-scoped
        let repoSlug = scope.contains("/") ? scope : nil
        guard let repo = repoSlug else { continue }
        let endpoint = "repos/\(repo)/actions/runs/\(runID)/jobs?per_page=100"
        guard
            let data = ghAPI(endpoint),
            let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else {
            log("fetchActiveJobs › decode failed for jobs of run \(runID)")
            continue
        }
        for j in resp.jobs {
            guard seenJobIDs.insert(j.id).inserted else { continue }
            guard j.conclusion == nil else { continue } // skip finished jobs
            jobs.append(ActiveJob(
                id:         j.id,
                name:       j.name,
                status:     j.status,
                conclusion: j.conclusion,
                startedAt:  j.startedAt.flatMap { iso.date(from: $0) },
                createdAt:  j.createdAt.flatMap { iso.date(from: $0) }
            ))
        }
    }

    log("fetchActiveJobs › \(jobs.count) active job(s) for \(scope)")
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
