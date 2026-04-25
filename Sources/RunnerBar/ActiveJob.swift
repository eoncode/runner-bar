import Foundation

// MARK: - JobStep

struct JobStep: Identifiable {
    let id: Int  // step number (1-based)
    let name: String
    let status: String        // queued, in_progress, completed
    let conclusion: String?   // success, failure, cancelled, skipped
    let startedAt: Date?
    let completedAt: Date?

    var elapsed: String {
        guard status != "queued" else { return "00:00" }
        guard let start = startedAt else { return "00:00" }
        let end = completedAt ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        let m = sec / 60; let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    var conclusionIcon: String {
        switch conclusion {
        case "success":   return "✓"
        case "failure":   return "✗"
        case "cancelled": return "⊖"
        case "skipped":   return "−"
        default:
            switch status {
            case "in_progress": return "⟳"
            case "queued":      return "○"
            default:            return "•"
            }
        }
    }

    var conclusionColor: String {
        switch conclusion {
        case "success":  return "green"
        case "failure":  return "red"
        case "skipped":  return "secondary"
        default:         return "secondary"
        }
    }
}

// MARK: - ActiveJob

struct ActiveJob: Identifiable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let createdAt: Date?
    let completedAt: Date?
    var isDimmed: Bool = false
    var steps: [JobStep] = []

    /// queued → 00:00 | in_progress → live | completed → frozen
    var elapsed: String {
        guard status != "queued" else { return "00:00" }
        guard let start = startedAt ?? createdAt else { return "00:00" }
        let end = completedAt ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        let m = sec / 60; let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - gh API

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

// MARK: - Fetch all jobs from active runs

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
            let steps: [JobStep] = (j.steps ?? []).enumerated().map { idx, s in
                JobStep(
                    id:          idx + 1,
                    name:        s.name,
                    status:      s.status,
                    conclusion:  s.conclusion,
                    startedAt:   s.startedAt.flatMap   { iso.date(from: $0) },
                    completedAt: s.completedAt.flatMap { iso.date(from: $0) }
                )
            }
            jobs.append(ActiveJob(
                id:          j.id,
                name:        j.name,
                status:      j.status,
                conclusion:  j.conclusion,
                startedAt:   j.startedAt.flatMap   { iso.date(from: $0) },
                createdAt:   j.createdAt.flatMap   { iso.date(from: $0) },
                completedAt: j.completedAt.flatMap { iso.date(from: $0) },
                steps:       steps
            ))
        }
    }
    log("fetchActiveJobs › \(jobs.count) job(s) for \(scope)")
    return jobs
}

// MARK: - Codable helpers

private struct WorkflowRunsResponse: Codable {
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}
private struct WorkflowRun: Codable { let id: Int }
private struct JobsResponse: Codable { let jobs: [JobPayload] }
private struct StepPayload: Codable {
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    enum CodingKeys: String, CodingKey {
        case name, status, conclusion
        case startedAt   = "started_at"
        case completedAt = "completed_at"
    }
}
private struct JobPayload: Codable {
    let id: Int; let name: String; let status: String
    let conclusion: String?
    let startedAt: String?
    let createdAt: String?
    let completedAt: String?
    let steps: [StepPayload]?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt   = "started_at"
        case createdAt   = "created_at"
        case completedAt = "completed_at"
    }
}
