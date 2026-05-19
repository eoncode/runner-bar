// swiftlint:disable colon identifier_name opening_brace cyclomatic_complexity function_body_length multiple_closures_with_trailing_closure type_body_length
import Foundation
import os

// MARK: - gh API

private let _rateLimitLock = OSAllocatedUnfairLock(initialState: false)

var ghIsRateLimited: Bool {
    get { _rateLimitLock.withLock { $0 } }
    set { _rateLimitLock.withLock { $0 = newValue } }
}

// MARK: - Process runner (private)

private func runGHProcess(arguments: [String], timeout: TimeInterval = 20) -> Data? {
    guard let ghPath = ghBinaryPath() else {
        log("runGHProcess › gh not found in known paths")
        return nil
    }
    log("runGHProcess › \(ghPath) \(arguments.joined(separator: " "))")
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
    log("runGHProcess › exit=\(task.terminationStatus) bytes=\(outputData.count)")
    return outputData.isEmpty ? nil : outputData
}

// MARK: - Public gh wrappers

func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard let outputData = runGHProcess(arguments: ["api", endpoint], timeout: timeout) else {
        return nil
    }
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
    for status in ["in_progress", "queued"] {
        guard let data = ghAPI(runsEndpoint(status: status)),
              let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        else { continue }
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
        guard let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
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
    log("fetchRegistrationToken › POSTing \(endpoint)")
    let args = ["api", "--method", "POST",
                "-H", "Accept: application/vnd.github+json", endpoint]
    guard let outputData = runGHProcess(arguments: args, timeout: 30) else {
        log("fetchRegistrationToken › no data for \(endpoint)")
        return nil
    }
    // NOTE: raw response intentionally not logged — it contains a short-lived token.
    log("fetchRegistrationToken › \(endpoint) \(outputData.count)b raw=[REDACTED]")
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("fetchRegistrationToken › decode failed for \(endpoint) (\(outputData.count)b)")
        return nil
    }
    log("fetchRegistrationToken › got token (first 4): \(resp.token.prefix(4))...")
    return resp.token
}

// MARK: - Removal token

/// Fetches a runner removal token for the given scope (owner/repo or org).
/// The removal token is required by `config.sh remove --token <token>`.
func fetchRemovalToken(scope: String) -> String? {
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners/remove-token"
    } else {
        endpoint = "orgs/\(scope)/actions/runners/remove-token"
    }
    log("fetchRemovalToken › POSTing \(endpoint)")
    let args = ["api", "--method", "POST",
                "-H", "Accept: application/vnd.github+json", endpoint]
    guard let outputData = runGHProcess(arguments: args, timeout: 30) else {
        log("fetchRemovalToken › no data returned for \(endpoint)")
        return nil
    }
    // NOTE: raw response intentionally not logged — it contains a short-lived token.
    log("fetchRemovalToken › raw response (\(outputData.count)b): [REDACTED]")
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("fetchRemovalToken › decode failed for \(endpoint) (\(outputData.count)b)")
        return nil
    }
    log("fetchRemovalToken › got removal token (first 4): \(resp.token.prefix(4))...")
    return resp.token
}

// MARK: - Delete runner by ID (API fallback for corrupt installs)

/// Directly deregisters a runner from GitHub via DELETE API.
/// Used as fallback when config.sh is missing or corrupt.
/// Returns true only if the runner was successfully deleted (HTTP 204, gh exit 0).
/// A 404 response means the runner ID was not found — that is a failure, not a deletion.
@discardableResult
func deleteRunnerByID(scope: String, runnerID: Int) -> Bool {
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners/\(runnerID)"
    } else {
        endpoint = "orgs/\(scope)/actions/runners/\(runnerID)"
    }
    log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)")
    guard let ghPath = ghBinaryPath() else {
        log("deleteRunnerByID › gh not found")
        return false
    }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", "--method", "DELETE",
                      "-H", "Accept: application/vnd.github+json", endpoint]
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch {
        log("deleteRunnerByID › launch error: \(error)")
        return false
    }
    let timeoutItem = DispatchWorkItem { task.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    let outData = pipe.fileHandleForReading.readDataToEndOfFile()
    let raw = String(data: outData, encoding: .utf8) ?? ""
    let status = task.terminationStatus
    log("deleteRunnerByID › exit=\(status) response=\(raw.prefix(200))")
    // GitHub DELETE returns 204 No Content on success — gh exits 0.
    // Any non-zero exit (including 404 Not Found) is a genuine failure.
    let ok = status == 0
    if !ok {
        log("deleteRunnerByID › DELETE failed (exit=\(status)) for runnerID=\(runnerID) — runner may still exist on GitHub")
    }
    log("deleteRunnerByID › result=\(ok) for runnerID=\(runnerID)")
    return ok
}

// MARK: - Patch runner labels (#492)

/// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
/// The built-in labels (self-hosted, OS, arch) are preserved by GitHub automatically.
/// Returns the updated label names on success, or nil on failure.
@discardableResult
func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) -> [String]? {
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners/\(runnerID)/labels"
    } else {
        endpoint = "orgs/\(scope)/actions/runners/\(runnerID)/labels"
    }
    log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)")
    // Build JSON body: {"labels": ["label1","label2"]}
    guard let bodyData = try? JSONSerialization.data(withJSONObject: ["labels": labels]),
          let bodyString = String(data: bodyData, encoding: .utf8),
          let ghPath = ghBinaryPath()
    else {
        log("patchRunnerLabels › failed to build request")
        return nil
    }
    let task = Process()
    let pipe = Pipe()
    let errPipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = [
        "api",
        "--method", "PUT",
        "-H", "Accept: application/vnd.github+json",
        "-H", "Content-Type: application/json",
        "--input", "-",
        endpoint
    ]
    task.standardOutput = pipe
    task.standardError = errPipe
    let inputPipe = Pipe()
    task.standardInput = inputPipe
    do { try task.run() } catch {
        log("patchRunnerLabels › launch error: \(error)")
        return nil
    }
    inputPipe.fileHandleForWriting.write(bodyData)
    inputPipe.fileHandleForWriting.closeFile()
    let timeoutItem = DispatchWorkItem { task.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    let outData = pipe.fileHandleForReading.readDataToEndOfFile()
    let raw = String(data: outData, encoding: .utf8) ?? ""
    log("patchRunnerLabels › exit=\(task.terminationStatus) response=\(raw.prefix(300))")
    guard task.terminationStatus == 0 else {
        log("patchRunnerLabels › non-zero exit for endpoint=\(endpoint) body=\(bodyString)")
        return nil
    }
    struct LabelsResponse: Decodable {
        struct Label: Decodable { let name: String }
        let labels: [Label]
    }
    guard let resp = try? JSONDecoder().decode(LabelsResponse.self, from: outData) else {
        log("patchRunnerLabels › decode failed raw=\(raw.prefix(200))")
        return nil
    }
    let names = resp.labels.map(\.name)
    log("patchRunnerLabels › success labels=\(names)")
    return names
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
    let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    if found == nil { log("ghBinaryPath › gh not found in \(candidates)") }
    return found
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
    let timeoutItem = DispatchWorkItem { task.terminate() }
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
// swiftlint:enable colon identifier_name opening_brace cyclomatic_complexity function_body_length multiple_closures_with_trailing_closure type_body_length
