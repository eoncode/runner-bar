import Foundation

// MARK: - gh API

/// Set to `true` when any `ghAPI` call receives a 403/429 rate-limit response.
/// Reset to `false` at the start of each `RunnerStore.fetch()` poll cycle.
/// Intentionally non-atomic: a one-cycle lag in the UI warning is acceptable.
var ghIsRateLimited: Bool = false

/// Calls the GitHub CLI (`gh api`) with the given endpoint and returns raw response data.
/// Returns `nil` on launch failure, timeout, empty response, or rate-limit (403/429).
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    // swiftlint:disable:next identifier_name
    guard let gh = ghBinaryPath() else {
        log("ghAPI › gh not found")
        return nil
    }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: gh)
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
    if let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
       let status = json["status"] as? String,
       status == "403" || status == "429" {
        ghIsRateLimited = true
        log("ghAPI › rate limit (\(status)): \(endpoint)")
        return nil
    }
    return outputData.isEmpty ? nil : outputData
}

// MARK: - URL helpers

/// Extracts the "owner/repo" scope from a GitHub Actions job HTML URL.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3
    else { return nil }
    let components = url.pathComponents
    return "\(components[1])/\(components[2])"
}

/// Extracts the workflow run ID from a GitHub Actions job HTML URL.
func runIDFromHtmlUrl(_ url: String?) -> Int? {
    guard let url else { return nil }
    let parts = url.components(separatedBy: "/")
    for (idx, part) in parts.enumerated() {
        if part == "runs", idx + 1 < parts.count {
            return Int(parts[idx + 1])
        }
    }
    return nil
}

// MARK: - Fetch all jobs from active runs

/// Fetches all active (in_progress + queued) jobs across all runs for the given scope.
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
        // insert+append pattern cannot be expressed as a where clause
        // swiftlint:disable for_where
        for run in resp.workflowRuns {
            if seenRunIDs.insert(run.id).inserted { runIDs.append(run.id) }
        }
        // swiftlint:enable for_where
    }

    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()

    for runID in runIDs {
        guard scope.contains("/") else { continue }
        guard
            let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
            let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else { continue }
        for payload in resp.jobs {
            guard seenJobIDs.insert(payload.id).inserted else { continue }
            jobs.append(makeActiveJob(from: payload, iso: iso, isDimmed: false))
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

// MARK: - Runners

/// Fetches all self-hosted runners for the given scope via the GitHub CLI.
func fetchRunners(for scope: String) -> [Runner] {
    let path: String
    if scope.contains("/") {
        path = "/repos/\(scope)/actions/runners"
    } else {
        path = "/orgs/\(scope)/actions/runners"
    }
    log("fetchRunners › \(path)")
    let json = shell("/opt/homebrew/bin/gh api \(path)")
    log("fetchRunners › response prefix: \(json.prefix(120))")
    guard
        let data = json.data(using: .utf8),
        let response = try? JSONDecoder().decode(RunnersResponse.self, from: data)
    else {
        log("fetchRunners › decode failed for scope: \(scope)")
        return []
    }
    log("fetchRunners › found \(response.runners.count) runner(s) for \(scope)")
    // Enrich with gitHubUrl for Phase 4 API enrichment
    let gitHubUrl = scope.contains("/") ? "https://github.com/\(scope)" : "https://github.com/\(scope)"
    return response.runners.map {
        var runner = $0
        runner.gitHubUrl = gitHubUrl
        return runner
    }
}

private struct RunnersResponse: Codable {
    let runners: [Runner]
}

// MARK: - Step log

/// Fetch and slice the raw log for a single step.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard scope.contains("/") else {
        log("fetchStepLog › skipped: org-scoped logs not supported (scope=\(scope))")
        return nil
    }
    guard let ghPath = ghBinaryPath() else {
        log("fetchStepLog › gh not found")
        return nil
    }
    let endpoint = "repos/\(scope)/actions/jobs/\(jobID)/logs"
    log("fetchStepLog › fetching \(endpoint) step=\(stepNumber)")
    let raw = shell(
        "\(ghPath) api \(endpoint) --header \"Accept: application/vnd.github.v3.raw\""
    )
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty response for job \(jobID)")
        return nil
    }
    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))")
        return nil
    }
    let cleaned = stripAnsi(raw)
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [String] = []
    var current: [String] = []
    for line in lines {
        if line.contains("##[group]") {
            if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
            current = [line]
        } else {
            current.append(line)
        }
    }
    if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
    log("fetchStepLog › parsed \(sections.count) section(s) from log")
    if sections.isEmpty || (sections.count == 1 && !sections[0].contains("##[group]")) {
        log("fetchStepLog › no group markers, returning full raw log")
        return cleaned
    }
    let index = stepNumber - 1
    guard index >= 0, index < sections.count else {
        log(
            "fetchStepLog › stepNumber \(stepNumber) out of range "
            + "(sections=\(sections.count)), returning full log"
        )
        return cleaned
    }
    let section = sections[index]
    log("fetchStepLog › step \(stepNumber) → \(section.count)ch")
    return section.isEmpty ? cleaned : section
}

private func stripAnsi(_ input: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\u001B\\[[0-9;]*[A-Za-z]") else {
        return input
    }
    return regex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""
    )
}

// MARK: - Shared gh binary path

/// Returns the first executable `gh` binary found on common install paths.
func ghBinaryPath() -> String? {
    let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

// MARK: - POST helper

/// Fires a POST to the GitHub API via `gh api --method POST`.
/// Returns `true` if gh exits 0 (HTTP 2xx), `false` otherwise.
/// Must be called from a background thread.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    guard let ghPath = ghBinaryPath() else {
        log("ghPost › gh not found")
        return false
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", "--method", "POST", "-H", "Accept: application/vnd.github+json", endpoint]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        log("ghPost › launch error: \(error)")
        return false
    }
    let timeoutItem = DispatchWorkItem(block: { task.terminate() })
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    log("ghPost › \(endpoint) exit \(task.terminationStatus)")
    return task.terminationStatus == 0
}

// MARK: - Cancel run

/// Cancels a workflow run via POST `.../cancel`.
/// Returns `true` on HTTP 202, `false` on error or 409 (already completed).
/// Must be called from a background thread.
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
