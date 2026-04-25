import Foundation

// MARK: - Model

struct ActiveJob: Identifiable {
    let id: Int
    let runID: Int        // parent workflow run ID (used for matrix grouping)
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let createdAt: Date?
    let completedAt: Date?
    var isDimmed: Bool = false

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

    /// The base name before a matrix variant suffix like " (ubuntu-latest)".
    /// "build (ubuntu-latest)" → "build"
    /// "lint" → "lint"
    var matrixBaseName: String {
        if let paren = name.firstIndex(of: "(") {
            return String(name[name.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// The matrix variant label inside parentheses, or nil if not a matrix job.
    /// "build (ubuntu-latest)" → "ubuntu-latest"
    var matrixVariant: String? {
        guard let open = name.firstIndex(of: "("),
              let close = name.lastIndex(of: ")")
        else { return nil }
        let start = name.index(after: open)
        guard start < close else { return nil }
        return String(name[start..<close])
    }
}

// MARK: - Matrix grouping

/// A display unit in the jobs list: either a single standalone job,
/// or a collapsed group of matrix sibling jobs sharing the same runID + base name.
enum JobGroup: Identifiable {
    case single(ActiveJob)
    case matrix(baseName: String, jobs: [ActiveJob])

    var id: String {
        switch self {
        case .single(let j):           return "s-\(j.id)"
        case .matrix(let name, let jobs): return "m-\(jobs.first?.runID ?? 0)-\(name)"
        }
    }

    /// Aggregate status of the group: worst-case wins.
    var status: String {
        switch self {
        case .single(let j): return j.status
        case .matrix(_, let jobs):
            if jobs.contains(where: { $0.status == "in_progress" }) { return "in_progress" }
            if jobs.contains(where: { $0.status == "queued" })      { return "queued" }
            return "completed"
        }
    }

    var isDimmed: Bool {
        switch self {
        case .single(let j):      return j.isDimmed
        case .matrix(_, let jobs): return jobs.allSatisfy { $0.isDimmed }
        }
    }

    /// Elapsed of the longest-running child (or single job).
    var elapsed: String {
        switch self {
        case .single(let j): return j.elapsed
        case .matrix(_, let jobs):
            return jobs.map { $0.elapsed }.max() ?? "00:00"
        }
    }

    var conclusion: String? {
        switch self {
        case .single(let j): return j.conclusion
        case .matrix(_, let jobs):
            if jobs.contains(where: { $0.conclusion == "failure" })  { return "failure" }
            if jobs.contains(where: { $0.conclusion == nil })        { return nil }
            return "success"
        }
    }

    var displayName: String {
        switch self {
        case .single(let j):           return j.name
        case .matrix(let name, let jobs): return "\(name) (\(jobs.count) variants)"
        }
    }
}

/// Groups a flat list of ActiveJob into JobGroups.
/// Jobs sharing the same runID AND matrixBaseName (and having a matrixVariant) are collapsed.
func groupJobs(_ jobs: [ActiveJob]) -> [JobGroup] {
    // Identify matrix candidates: jobs with a variant suffix
    var matrixBuckets: [String: [ActiveJob]] = [:]  // key = "\(runID)-\(baseName)"
    var standaloneIDs = Set<Int>()

    for job in jobs {
        if job.matrixVariant != nil {
            let key = "\(job.runID)-\(job.matrixBaseName)"
            matrixBuckets[key, default: []].append(job)
        } else {
            standaloneIDs.insert(job.id)
        }
    }

    // Any bucket with only 1 job is not truly a matrix — treat as standalone
    for (key, bucket) in matrixBuckets where bucket.count < 2 {
        bucket.forEach { standaloneIDs.insert($0.id) }
        matrixBuckets.removeValue(forKey: key)
    }

    var groups: [JobGroup] = []
    var seen = Set<Int>()

    for job in jobs {
        guard !seen.contains(job.id) else { continue }
        if standaloneIDs.contains(job.id) {
            groups.append(.single(job))
            seen.insert(job.id)
        } else {
            let key = "\(job.runID)-\(job.matrixBaseName)"
            if let bucket = matrixBuckets[key] {
                groups.append(.matrix(baseName: job.matrixBaseName, jobs: bucket))
                bucket.forEach { seen.insert($0.id) }
                matrixBuckets.removeValue(forKey: key)  // emit once
            }
        }
    }
    return groups
}

// MARK: - gh API

func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
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
            jobs.append(ActiveJob(
                id:          j.id,
                runID:       runID,
                name:        j.name,
                status:      j.status,
                conclusion:  j.conclusion,
                startedAt:   j.startedAt.flatMap   { iso.date(from: $0) },
                createdAt:   j.createdAt.flatMap   { iso.date(from: $0) },
                completedAt: j.completedAt.flatMap { iso.date(from: $0) }
            ))
        }
    }
    log("fetchActiveJobs › \(jobs.count) total job(s) for \(scope)")
    return jobs
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
