import Foundation

// MARK: - JobStep

/// A single step within a GitHub Actions job, decoded from the GitHub API.
struct JobStep: Identifiable {
    let id: Int        // step number (1-based)
    let name: String
    let status: String       // queued, in_progress, completed
    let conclusion: String?  // success, failure, cancelled, skipped
    let startedAt: Date?
    let completedAt: Date?

    var elapsed: String {
        guard status != "queued" else { return "00:00" }
        guard let start = startedAt else { return "00:00" }
        let end = completedAt ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        let minutes = sec / 60
        let seconds = sec % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var conclusionIcon: String {
        switch conclusion {
        case "success": return "✓"
        case "failure": return "✗"
        case "cancelled": return "⊖"
        case "skipped": return "−"
        default:
            switch status {
            case "in_progress": return "⟳"
            case "queued": return "○"
            default: return "•"
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
// 1. fetchActiveJobs() — live jobs fetched from the GitHub API
// 2. Vanished-job freeze block — RunnerStore.fetch(), "snapPrev" diff loop
// 3. Fresh-done freeze block — RunnerStore.fetch(), "freshDone" loop
//
// Before pushing any model change, verify:
// grep -rn 'ActiveJob(' Sources/

/// A GitHub Actions job currently active (in-progress, queued) or recently completed.
struct ActiveJob: Identifiable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let createdAt: Date?
    let completedAt: Date?
    let htmlUrl: String?  // GitHub job page URL
    var isDimmed: Bool = false
    var steps: [JobStep] = []

    var elapsed: String {
        guard status != "queued" else { return "00:00" }
        // Completed jobs: use only real execution timestamps — never createdAt.
        // createdAt is queue creation time and inflates elapsed for long-queued jobs.
        if conclusion != nil {
            guard let start = startedAt, let end = completedAt else { return "--:--" }
            let sec = Int(end.timeIntervalSince(start))
            guard sec >= 0 else { return "--:--" }
            let minutes = sec / 60
            let seconds = sec % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
        // Live jobs: createdAt fallback is acceptable while startedAt may not yet be set.
        guard let start = startedAt ?? createdAt else { return "00:00" }
        let end = completedAt ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        guard sec >= 0 else { return "00:00" }
        let minutes = sec / 60
        let seconds = sec % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - gh API

/// Set to `true` when any `ghAPI` call receives a 403/429 rate-limit response.
/// Reset to `false` at the start of each `RunnerStore.fetch()` poll cycle.
/// Intentionally non-atomic: a one-cycle lag in the UI warning is acceptable.
var ghIsRateLimited: Bool = false

/// Calls the GitHub CLI (`gh api`) with the given endpoint and returns raw response data.
/// Internal so `ActionGroup.swift` can reuse it without duplicating networking code.
/// Returns `nil` on launch failure, timeout, or empty response.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    let ghPath = "/opt/homebrew/bin/gh"
    guard FileManager.default.isExecutableFile(atPath: ghPath) else {
        log("ghAPI › gh not found at \(ghPath)")
        return nil
    }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", endpoint]
    task.standardOutput = pipe
    task.standardError = Pipe()
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
    // Detect rate limit — gh api returns a JSON error body with a "status" field.
    // Only set the flag to true here; reset happens at the top of each fetch() cycle.
    if let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
       let status = json["status"] as? String,
       status == "403" || status == "429" {
        ghIsRateLimited = true
        log("ghAPI › rate limit (\(status)): \(endpoint)")
        return nil
    }
    return outputData.isEmpty ? nil : outputData
}

// MARK: - Fetch all jobs from active runs

/// Fetches all active (in-progress and queued) jobs for the given scope.
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
        guard let data = ghAPI(runsEndpoint(status: status)),
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
        guard let data = ghAPI(
            "repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"
        ), let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else { continue }
        for jobPayload in resp.jobs {
            guard seenJobIDs.insert(jobPayload.id).inserted else { continue }
            let steps: [JobStep] = (jobPayload.steps ?? []).enumerated().map { idx, stepPayload in
                JobStep(
                    id: idx + 1,
                    name: stepPayload.name,
                    status: stepPayload.status,
                    conclusion: stepPayload.conclusion,
                    startedAt: stepPayload.startedAt.flatMap { iso.date(from: $0) },
                    completedAt: stepPayload.completedAt.flatMap { iso.date(from: $0) }
                )
            }
            // ⚠️ CALLSITE 1 of 3 — see ActiveJob callsite warning above
            jobs.append(ActiveJob(
                id: jobPayload.id,
                name: jobPayload.name,
                status: jobPayload.status,
                conclusion: jobPayload.conclusion,
                startedAt: jobPayload.startedAt.flatMap { iso.date(from: $0) },
                createdAt: jobPayload.createdAt.flatMap { iso.date(from: $0) },
                completedAt: jobPayload.completedAt.flatMap { iso.date(from: $0) },
                htmlUrl: jobPayload.htmlUrl,
                steps: steps
            ))
        }
    }
    log("fetchActiveJobs › \(jobs.count) job(s) for \(scope)")
    return jobs
}

// MARK: - URL helpers

/// Extracts the "owner/repo" scope from a GitHub Actions job HTML URL.
/// Pattern: https://github.com/owner/repo/actions/runs/...
/// Returns nil if the URL is missing or has fewer than 3 path components.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3
    else { return nil }
    let components = url.pathComponents // ["/", "owner", "repo", "actions", ...]
    return "\(components[1])/\(components[2])"
}

/// Extracts the workflow run ID from a GitHub Actions job HTML URL.
/// URL pattern: https://github.com/{owner}/{repo}/actions/runs/{run_id}/jobs/{job_id}
/// Returns nil for nil or malformed URLs.
func runIDFromHtmlUrl(_ url: String?) -> Int? {
    guard let url else { return nil }
    let parts = url.components(separatedBy: "/")
    for (index, part) in parts.enumerated() {
        if part == "runs", index + 1 < parts.count {
            return Int(parts[index + 1])
        }
    }
    return nil
}

// MARK: - Codable helpers

/// Response wrapper for the GitHub workflow runs list endpoint.
struct WorkflowRunsResponse: Codable {
    let workflowRuns: [WorkflowRun]
    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

/// A single workflow run, used only to extract the run ID.
struct WorkflowRun: Codable {
    let id: Int
}

/// Internal so `ActionGroup.swift` can decode job lists without duplicating structs.
struct JobsResponse: Codable {
    let jobs: [JobPayload]
}

/// Raw step data decoded from the GitHub API jobs response.
struct StepPayload: Codable {
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    enum CodingKeys: String, CodingKey {
        case name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

/// Raw job data decoded from the GitHub API jobs response.
struct JobPayload: Codable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let createdAt: String?
    let completedAt: String?
    let htmlUrl: String?
    let steps: [StepPayload]?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, steps
        case startedAt = "started_at"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case htmlUrl = "html_url"
    }
}
