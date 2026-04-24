import Foundation

// MARK: - Model

struct ActiveJob: Identifiable {
    let id: Int
    let name: String
    let status: String       // "queued", "in_progress", "completed"
    let conclusion: String?  // nil when truly active; non-nil for completed tail
    let startedAt: Date?
    let createdAt: Date?
    let completedAt: Date?   // non-nil for completed jobs — freezes elapsed
    var isDimmed: Bool = false

    /// Elapsed time:
    /// - queued jobs (not yet started): "—"
    /// - completed jobs: frozen start → completedAt
    /// - active jobs: live start → now
    var elapsed: String {
        guard status != "queued" else { return "—" }
        guard let start = startedAt ?? createdAt else { return "—" }
        let end = completedAt ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        guard sec >= 0 else { return "—" }
        let m = sec / 60; let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - gh API (direct Process, no shell — avoids & metachar splitting)

private func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    let gh = "/opt/homebrew/bin/gh"
    guard FileManager.default.isExecutableFile(atPath: gh) else {
        log("ghAPI › gh not found at \(gh)")
        return nil
    }
    let task = Process()
    let pipe = Pipe()
    task.executableURL  = URL(fileURLWithPath: gh)
    task.arguments      = ["api", endpoint]
    task.standardOutput = pipe
    task.standardError  = Pipe()

    var outputData = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock(); outputData.append(chunk); lock.unlock()
    }
    do { try task.run() } catch {
        log("ghAPI › launch error: \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning {
        if Date() > deadline { task.terminate(); break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
    log("ghAPI › \(endpoint) → \(outputData.count)b exit \(task.terminationStatus)")
    return outputData.isEmpty ? nil : outputData
}

// MARK: - Fetch active jobs

func fetchActiveJobs(for scope: String) -> [ActiveJob] {
    let iso = ISO8601DateFormatter()
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    func runsEndpoint(status: String) -> String {
        scope.contains("/")
            ? "repos/\(scope)/actions/runs?status=\(status)&per_page=50"
            : "orgs/\(scope)/actions/runs?status=\(status)&per_page=50"
    }

    for status in ["in_progress", "queued"] {
        guard
            let data = ghAPI(runsEndpoint(status: status)),
            let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        else { continue }
        for run in resp.workflowRuns {
            if seenRunIDs.insert(run.id).inserted { runIDs.append(run.id) }
        }
    }

    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()

    for runID in runIDs {
        guard scope.contains("/") else { continue }
        guard
            let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
            let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else { continue }
        for j in resp.jobs {
            guard seenJobIDs.insert(j.id).inserted else { continue }
            guard j.conclusion == nil else { continue }
            jobs.append(ActiveJob(
                id: j.id, name: j.name, status: j.status, conclusion: j.conclusion,
                startedAt:   j.startedAt.flatMap   { iso.date(from: $0) },
                createdAt:   j.createdAt.flatMap   { iso.date(from: $0) },
                completedAt: nil
            ))
        }
    }
    log("fetchActiveJobs › \(jobs.count) active job(s) for \(scope)")
    return jobs.sorted { rank($0) < rank($1) }
}

// MARK: - Fetch completed tail (last 3 jobs from most recent completed run)

func fetchRecentCompletedJobs(for scope: String) -> [ActiveJob] {
    guard scope.contains("/") else { return [] }
    let iso = ISO8601DateFormatter()

    guard
        let data = ghAPI("repos/\(scope)/actions/runs?status=completed&per_page=5"),
        let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data),
        let run  = resp.workflowRuns.first
    else { return [] }

    guard
        let jdata = ghAPI("repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=30"),
        let jresp = try? JSONDecoder().decode(JobsResponse.self, from: jdata)
    else { return [] }

    let completed = jresp.jobs
        .filter { $0.conclusion != nil }
        .sorted { ($0.startedAt ?? "") > ($1.startedAt ?? "") }
        .prefix(3)

    return completed.map { j in
        ActiveJob(
            id: j.id, name: j.name, status: j.status, conclusion: j.conclusion,
            startedAt:   j.startedAt.flatMap   { iso.date(from: $0) },
            createdAt:   j.createdAt.flatMap   { iso.date(from: $0) },
            completedAt: j.completedAt.flatMap { iso.date(from: $0) },
            isDimmed: true
        )
    }
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
    let id: Int; let name: String; let status: String
    let conclusion: String?
    let startedAt: String?
    let createdAt: String?
    let completedAt: String?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case startedAt   = "started_at"
        case createdAt   = "created_at"
        case completedAt = "completed_at"
    }
}
