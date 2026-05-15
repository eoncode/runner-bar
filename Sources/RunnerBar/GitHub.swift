import Foundation
import os

// MARK: - gh API

/// Thread-safe rate-limit flag.
private let _rateLimitLock = OSAllocatedUnfairLock(initialState: false)

var ghIsRateLimited: Bool {
    get { _rateLimitLock.withLock { $0 } }
    set { _rateLimitLock.withLock { $0 = newValue } }
}

// MARK: - Process runner (private)

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

func ghAPI(_ endpoint: String, method: String = "GET", timeout: TimeInterval = 20) -> Data? {
    var args = ["api"]
    if method != "GET" { args += ["--method", method] }
    args.append(endpoint)
    guard let outputData = runGHProcess(arguments: args, timeout: timeout) else { return nil }
    log("ghAPI › \(endpoint) → \(outputData.count)b")
    if let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
       let status = json["status"] as? String,
       status == "403" || status == "429" {
        ghIsRateLimited = true
        log("ghAPI › rate limit (\(status)): \(endpoint)")
        return nil
    }
    return outputData
}

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

func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3 else { return nil }
    let components = url.pathComponents
    return "\(components[1])/\(components[2])"
}

func runIDFromHtmlUrl(_ url: String?) -> Int? {
    guard let url else { return nil }
    let parts = url.components(separatedBy: "/")
    for (idx, part) in parts.enumerated() {
        if part == "runs", idx + 1 < parts.count { return Int(parts[idx + 1]) }
    }
    return nil
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
    // GHWorkflowRunID is a private local struct to avoid clash with the public WorkflowRun.
    struct GHWorkflowRunID: Codable { let id: Int }
    struct GHWorkflowRunsResponse: Codable {
        let workflowRuns: [GHWorkflowRunID]
        enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
    }
    for status in ["in_progress", "queued"] {
        guard let data = ghAPI(runsEndpoint(status: status)),
              let resp = try? JSONDecoder().decode(GHWorkflowRunsResponse.self, from: data)
        else { continue }
        // swiftlint:disable for_where
        for run in resp.workflowRuns {
            if seenRunIDs.insert(run.id).inserted { runIDs.append(run.id) }
        }
        // swiftlint:enable for_where
    }
    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    let iso2 = ISO8601DateFormatter()
    for runID in runIDs {
        guard scope.contains("/") else { continue }
        guard let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
              let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else { continue }
        for payload in resp.jobs {
            guard seenJobIDs.insert(payload.id).inserted else { continue }
            jobs.append(ActiveJob(
                id: payload.id,
                name: payload.name,
                status: payload.status,
                conclusion: payload.conclusion,
                startedAt: payload.startedAt.flatMap { iso2.date(from: $0) },
                createdAt: payload.createdAt.flatMap { iso2.date(from: $0) },
                completedAt: payload.completedAt.flatMap { iso2.date(from: $0) },
                htmlUrl: payload.htmlUrl,
                isDimmed: false,
                steps: (payload.steps ?? []).map { s in
                    JobStep(id: s.number, name: s.name, status: s.status,
                            conclusion: s.conclusion,
                            startedAt: s.startedAt.flatMap { iso2.date(from: $0) },
                            completedAt: s.completedAt.flatMap { iso2.date(from: $0) })
                },
                runnerName: payload.runnerName
            ))
        }
    }
    log("fetchActiveJobs › \(jobs.count) job(s) for \(scope)")
    return jobs
}

// MARK: - Runners

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
    guard let response = try? JSONDecoder().decode(RunnersResponse.self, from: data) else {
        log("fetchRunners › decode failed for scope: \(scope)")
        return []
    }
    log("fetchRunners › found \(response.runners.count) runner(s) for \(scope)")
    return response.runners
}
private struct RunnersResponse: Codable { let runners: [Runner] }

// MARK: - User orgs and repos

func fetchUserOrgs() -> [String] {
    guard let data = ghAPIPaginated("/user/orgs?per_page=100") else { return [] }
    struct Org: Decodable { let login: String }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

func fetchUserRepos() -> [String] {
    guard let data = ghAPIPaginated("/user/repos?per_page=100&sort=updated") else { return [] }
    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    guard let repos = try? JSONDecoder().decode([Repo].self, from: data) else { return [] }
    return repos.map(\.fullName)
}

// MARK: - Registration token

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
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log(
            "fetchRegistrationToken › decode failed: "
                + "\(String(data: outputData, encoding: .utf8)?.prefix(120) ?? "")"
        )
        return nil
    }
    return resp.token
}

// MARK: - Step log

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
    guard let regex = try? NSRegularExpression(
        pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
    ) else { return input }
    return regex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""
    )
}

// MARK: - Shared gh binary path

func ghBinaryPath() -> String? {
    let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

// MARK: - POST helper

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

@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}

// MARK: - Re-run job

@discardableResult
func reRunJob(jobID: Int, repoSlug: String) -> Bool {
    guard repoSlug.contains("/") else {
        log("reRunJob › invalid repoSlug: \(repoSlug)")
        return false
    }
    let result = ghPost("repos/\(repoSlug)/actions/jobs/\(jobID)/rerun")
    log("reRunJob › job=\(jobID) repo=\(repoSlug) success=\(result)")
    return result
}

// MARK: - Re-run failed jobs

@discardableResult
func reRunFailedJobs(runID: Int, repoSlug: String) -> Bool {
    guard repoSlug.contains("/") else {
        log("reRunFailedJobs › invalid repoSlug: \(repoSlug)")
        return false
    }
    let result = ghPost("repos/\(repoSlug)/actions/runs/\(runID)/rerun-failed-jobs")
    log("reRunFailedJobs › run=\(runID) repo=\(repoSlug) success=\(result)")
    return result
}
