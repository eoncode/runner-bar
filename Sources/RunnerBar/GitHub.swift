import Foundation
import os


// MARK: - gh API

/// Thread-safe rate-limit flag.
/// Replaces the bare `var ghIsRateLimited: Bool` global that was written from
/// background threads without synchronization (data race, issue #399 item 2).
/// Access via `rateLimitLock.withLock { ... }` or the `ghIsRateLimited` computed
/// property below.
private let rateLimitLock = OSAllocatedUnfairLock(initialState: false)

/// Set to `true` when any `ghAPI` call receives a 403/429 rate-limit response.
/// Reset to `false` at the start of each `RunnerStore.fetch()` poll cycle.
var ghIsRateLimited: Bool {
    get { rateLimitLock.withLock { $0 } }
    set { rateLimitLock.withLock { $0 = newValue } }
}

// MARK: - Process runner (private)

/// Launches `gh` with the given arguments, streams stdout into a `Data` buffer,
/// and enforces a hard timeout. Shared by ghAPI, ghAPIPaginated, fetchRegistrationToken.
///
/// - Parameters:
///   - arguments: Arguments passed directly to the `gh` binary.
///   - timeout:   Kill timeout in seconds. Defaults to 20 s for API calls.
/// - Returns: Raw stdout bytes, or `nil` on launch failure or empty output.
private func runGHProcess(arguments: [String], timeout: TimeInterval = 20) -> Data? {
    guard let ghPath = ghBinaryPath() else {
        log("runGHProcess › gh not found")
        return nil
    }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = arguments
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
        log("runGHProcess › launch error: \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }
    let timeoutItem = DispatchWorkItem { task.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
    return outputData.isEmpty ? nil : outputData
}

// MARK: - Public gh wrappers

/// Calls the GitHub CLI (`gh api`) with the given endpoint and returns raw response data.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard let outputData = runGHProcess(arguments: ["api", endpoint], timeout: timeout) else {
        return nil
    }
    log("ghAPI › \(endpoint) → \(outputData.count)b")
    if let json = (try? JSONSerialization.jsonObject(with: outputData)) as? [String: Any],
       let status = json["status"] as? String,
       status == "403" || status == "429" {
        ghIsRateLimited = true
        log("ghAPI › rate limit (\(status)): \(endpoint)")
        return nil
    }
    return outputData
}

/// Calls `gh api --paginate` to follow Link rel=next automatically.
func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    guard let ghPath = ghBinaryPath() else { log("ghAPIPaginated › gh not found"); return nil }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", "--paginate", endpoint]
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
        log("ghAPIPaginated › launch error: \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }
    let timeoutItem = DispatchWorkItem { task.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
    log("ghAPIPaginated › \(endpoint) → \(outputData.count)b exit \(task.terminationStatus)")
    if task.terminationStatus != 0 {
        let raw = String(data: outputData, encoding: .utf8) ?? ""
        if raw.contains("\"403\"") || raw.contains("\"429\"") || raw.contains("rate limit") {
            ghIsRateLimited = true
            log("ghAPIPaginated › rate limit detected: \(endpoint)")
        } else {
            log("ghAPIPaginated › non-zero exit (\(task.terminationStatus)): \(endpoint)")
        }
        return nil
    }
    return outputData.isEmpty ? nil : outputData
}

// MARK: - URL helpers

/// Extracts the "owner/repo" scope from a GitHub Actions job HTML URL.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3 else { return nil }
    let components = url.pathComponents
    return "\(components[1])/\(components[2])"
}

/// Extracts the workflow run ID from a GitHub Actions job HTML URL.
func runIDFromHtmlUrl(_ url: String?) -> Int? {
    guard let url else { return nil }
    let parts = url.components(separatedBy: "/")
    for (idx, part) in parts.enumerated() {
        if part == "runs", idx + 1 < parts.count { return Int(parts[idx + 1]) }
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
        guard let data = ghAPI(runsEndpoint(status: status)) else { continue }
        do {
            let resp = try JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
            // swiftlint:disable for_where
            for run in resp.workflowRuns {
                if seenRunIDs.insert(run.id).inserted { runIDs.append(run.id) }
            }
            // swiftlint:enable for_where
        } catch {
            log("fetchActiveJobs › decode error (\(status)): \(error)")
        }
    }
    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    for runID in runIDs {
        guard scope.contains("/") else { continue }
        guard let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100") else { continue }
        do {
            let resp = try JSONDecoder().decode(JobsResponse.self, from: data)
            for payload in resp.jobs {
                guard seenJobIDs.insert(payload.id).inserted else { continue }
                jobs.append(makeActiveJob(from: payload, iso: iso, isDimmed: false))
            }
        } catch {
            log("fetchActiveJobs › jobs decode error (run \(runID)): \(error)")
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
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners"
    } else {
        endpoint = "orgs/\(scope)/actions/runners"
    }
    log("fetchRunners › \(endpoint)")
    guard let data = ghAPI(endpoint) else {
        log("fetchRunners › no data for scope: \(scope)")
        return []
    }
    do {
        let response = try JSONDecoder().decode(RunnersResponse.self, from: data)
        log("fetchRunners › found \(response.runners.count) runner(s) for \(scope)")
        return response.runners
    } catch {
        log("fetchRunners › decode failed for scope \(scope): \(error)")
        return []
    }
}
private struct RunnersResponse: Codable { let runners: [Runner] }

// MARK: - User orgs and repos

/// Returns the login names of all organisations the authenticated user belongs to.
func fetchUserOrgs() -> [String] {
    guard let data = ghAPIPaginated("/user/orgs?per_page=100") else { return [] }
    struct Org: Decodable { let login: String }
    do {
        let orgs = try JSONDecoder().decode([Org].self, from: data)
        return orgs.map(\.login)
    } catch {
        log("fetchUserOrgs › decode failed: \(error)")
        return []
    }
}

/// Returns `owner/repo` strings for the authenticated user's repositories.
func fetchUserRepos() -> [String] {
    guard let data = ghAPIPaginated("/user/repos?per_page=100&sort=updated") else { return [] }
    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    do {
        let repos = try JSONDecoder().decode([Repo].self, from: data)
        return repos.map(\.fullName)
    } catch {
        log("fetchUserRepos › decode failed: \(error)")
        return []
    }
}

// MARK: - Registration token

/// Fetches a runner registration token for the given scope.
func fetchRegistrationToken(scope: String) -> String? {
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners/registration-token"
    } else {
        endpoint = "orgs/\(scope)/actions/runners/registration-token"
    }
    let args = ["api", "--method", "POST",
                "-H", "Accept: application/vnd.github+json", endpoint]
    guard let outputData = runGHProcess(arguments: args, timeout: 30) else {
        log("fetchRegistrationToken › no data for \(endpoint)")
        return nil
    }
    log("fetchRegistrationToken › \(endpoint) \(outputData.count)b")
    struct TokenResponse: Decodable { let token: String }
    do {
        let resp = try JSONDecoder().decode(TokenResponse.self, from: outputData)
        return resp.token
    } catch {
        log("fetchRegistrationToken › decode failed: "
            + "\(String(data: outputData, encoding: .utf8)?.prefix(120) ?? "") error: \(error)")
        return nil
    }
}

// MARK: - Step log

/// Fetch and slice the raw log for a single step.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    guard scope.contains("/") else {
        log("fetchStepLog › skipped: org-scoped logs not supported (scope=\(scope))")
        return nil
    }
    guard let ghPath = ghBinaryPath() else { log("fetchStepLog › gh not found"); return nil }
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
    return sliceStepFromLog(raw: raw, stepNumber: stepNumber)
}

/// Slices a step section out of raw log text.
private func sliceStepFromLog(raw: String, stepNumber: Int) -> String {
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
        log("fetchStepLog › stepNumber \(stepNumber) out of range (sections=\(sections.count)), returning full log")
        return cleaned
    }
    let section = sections[index]
    log("fetchStepLog › step \(stepNumber) → \(section.count)ch")
    return section.isEmpty ? cleaned : section
}

private func stripAnsi(_ input: String) -> String {
    let pattern = "\u{001B}\\[[0-9;]*[A-Za-z]"
    do {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.stringByReplacingMatches(
            in: input,
            range: NSRange(input.startIndex..., in: input),
            withTemplate: ""
        )
    } catch {
        log("stripAnsi › regex compile error: \(error)")
        return input
    }
}

// MARK: - POST helper

/// Fires a POST to the GitHub API via `gh api --method POST`.
/// Returns `true` if gh exits 0 (HTTP 2xx), `false` otherwise.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    guard let ghPath = ghBinaryPath() else { log("ghPost › gh not found"); return false }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", "--method", "POST",
                      "-H", "Accept: application/vnd.github+json", endpoint]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do { try task.run() } catch {
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
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
// swiftlint:enable file_length
