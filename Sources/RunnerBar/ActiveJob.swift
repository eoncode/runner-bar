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
}

// MARK: - ActiveJob

// ⚠️ REGRESSION GUARD — callsites (ref issue #54)
// This struct is constructed in EXACTLY 3 places in RunnerStore.swift.
// If you add, remove, or rename ANY property, you MUST update all 3 sites
// in the SAME commit or the build will fail with "missing argument" errors.
//
// The 3 construction sites:
//   1. fetchActiveJobs()            — live jobs fetched from the GitHub API
//   2. Vanished-job freeze block    — RunnerStore.fetch(), "snapPrev" diff loop
//   3. Fresh-done freeze block      — RunnerStore.fetch(), "freshDone" loop
//
// Before pushing any model change, verify:
//   grep -rn 'ActiveJob(' Sources/
struct ActiveJob: Identifiable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let createdAt: Date?
    let completedAt: Date?
    let htmlUrl: String?       // GitHub job page URL
    var isDimmed: Bool = false
    var steps: [JobStep] = []

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

// MARK: - gh API (JSON)

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

// MARK: - gh API (raw text — for log endpoints)

// Same as ghAPI() but passes Accept: application/vnd.github.v3.raw
// so GitHub returns plain text instead of a redirect or JSON.
private func ghAPIRaw(_ endpoint: String, timeout: TimeInterval = 30) -> String? {
    let gh = "/opt/homebrew/bin/gh"
    guard FileManager.default.isExecutableFile(atPath: gh) else { return nil }
    let task = Process()
    let pipe = Pipe()
    task.executableURL  = URL(fileURLWithPath: gh)
    task.arguments      = ["api", endpoint, "--header", "Accept: application/vnd.github.v3.raw"]
    task.standardOutput = pipe
    task.standardError  = Pipe()
    var outputData = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let chunk = h.availableData
        guard !chunk.isEmpty else { return }
        lock.lock(); outputData.append(chunk); lock.unlock()
    }
    do { try task.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning {
        if Date() > deadline { task.terminate(); break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
    return outputData.isEmpty ? nil : String(data: outputData, encoding: .utf8)
}

// MARK: - Fetch step log

// Fetches the full job log and returns lines for the given step number (1-based).
// Called from StepLogView on a background thread — never call on main thread.
//
// GitHub Actions log format:
//   Each line: "2024-01-01T00:00:00.0000000Z <content>"
//   Steps are delimited by ##[group]<name> … ##[endgroup] blocks.
//   Block N (1-based) corresponds to step N.
//   Some simple jobs have no group markers — fallback returns all lines.
//
// Returns nil if gh is unavailable, auth fails, or network is down.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard !scope.isEmpty, scope.contains("/") else {
        log("fetchStepLog › no repo scope available")
        return nil
    }
    let endpoint = "repos/\(scope)/actions/jobs/\(jobID)/logs"
    guard let raw = ghAPIRaw(endpoint) else {
        log("fetchStepLog › failed to fetch log for job \(jobID)")
        return nil
    }

    let allLines = raw.components(separatedBy: "\n")
    var groupCount = 0
    var inTarget = false
    var result: [String] = []

    for rawLine in allLines {
        let line = stripLogTimestamp(stripANSI(rawLine))

        if line.contains("##[group]") {
            groupCount += 1
            inTarget = (groupCount == stepNumber)
            if inTarget {
                // Include the group label as a header line
                let label = line
                    .replacingOccurrences(of: "##[group]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { result.append(label) }
            }
            continue
        }
        if line.contains("##[endgroup]") {
            if inTarget { inTarget = false }
            continue
        }
        if inTarget && !line.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(line)
        }
    }

    // Fallback: no group markers → return all non-empty lines
    if result.isEmpty && groupCount == 0 {
        let fallback = allLines
            .map { stripLogTimestamp(stripANSI($0)) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return fallback.isEmpty ? nil : fallback.joined(separator: "\n")
    }

    return result.isEmpty ? nil : result.joined(separator: "\n")
}

// Strip ANSI escape sequences (ESC [ ... <letter>)
private func stripANSI(_ s: String) -> String {
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "\u{1B}" {
            var j = s.index(after: i)
            while j < s.endIndex {
                let ec = s[j]
                j = s.index(after: j)
                if ec.isLetter || ec == "m" || ec == "K" || ec == "J" || ec == "H" { break }
            }
            i = j
        } else {
            out.append(c)
            i = s.index(after: i)
        }
    }
    return out
}

// Strip GitHub Actions timestamp prefix: "YYYY-MM-DDTHH:MM:SS.0000000Z "
// Timestamps are exactly 29 chars including the trailing space.
private func stripLogTimestamp(_ s: String) -> String {
    guard s.count > 29 else { return s }
    let idx = s.index(s.startIndex, offsetBy: 29)
    let prefix = String(s[..<idx])
    if prefix.first?.isNumber == true && prefix.contains("T") && prefix.contains("Z") {
        return String(s[idx...])
    }
    return s
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
            // ⚠️ CALLSITE 1 of 3 — see ActiveJob callsite warning above
            jobs.append(ActiveJob(
                id:          j.id,
                name:        j.name,
                status:      j.status,
                conclusion:  j.conclusion,
                startedAt:   j.startedAt.flatMap   { iso.date(from: $0) },
                createdAt:   j.createdAt.flatMap   { iso.date(from: $0) },
                completedAt: j.completedAt.flatMap { iso.date(from: $0) },
                htmlUrl:     j.htmlUrl,
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
    let htmlUrl: String?
    let steps: [StepPayload]?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt   = "started_at"
        case createdAt   = "created_at"
        case completedAt = "completed_at"
        case htmlUrl     = "html_url"
    }
}
