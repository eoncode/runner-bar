import Foundation

// MARK: - gh CLI subprocess transport
//
// All functions in this file call the `gh` CLI binary via Process.
// runGHProcess() is the shared primitive; all other functions use it.

// MARK: - Shared gh binary path

func ghBinaryPath() -> String? {
    let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    if found == nil { log("ghBinaryPath › gh not found in \(candidates)") }
    return found
}

// MARK: - Core subprocess primitive

func runGHProcess(arguments: [String], timeout: TimeInterval = 20) -> Data? {
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

// MARK: - CLI API wrappers

func ghAPICLI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard let outputData = runGHProcess(arguments: ["api", endpoint], timeout: timeout) else {
        return nil
    }
    log("ghAPICLI › \(endpoint) → \(outputData.count)b")
    if let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
       let status = json["status"] as? String,
       status == "403" || status == "429" {
        ghIsRateLimited = true
        log("ghAPICLI › rate limit (\(status)): \(endpoint)")
        return nil
    }
    return outputData
}

func ghAPIPaginatedCLI(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    guard let ghPath = ghBinaryPath() else { log("ghAPIPaginatedCLI › gh not found"); return nil }
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
        log("ghAPIPaginatedCLI › launch error: \(error)")
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
    log("ghAPIPaginatedCLI › \(endpoint) → \(outputData.count)b exit \(task.terminationStatus)")
    if task.terminationStatus != 0 {
        let raw = String(data: outputData, encoding: .utf8) ?? ""
        if raw.contains("\"403\"") || raw.contains("\"429\"") || raw.contains("rate limit") {
            ghIsRateLimited = true
            log("ghAPIPaginatedCLI › rate limit detected: \(endpoint)")
        } else {
            log("ghAPIPaginatedCLI › non-zero exit (\(task.terminationStatus)): \(endpoint)")
        }
        return nil
    }
    return outputData.isEmpty ? nil : outputData
}

// MARK: - Runner mutation helpers

/// Directly deregisters a runner from GitHub via DELETE API.
/// Returns true only if the runner was successfully deleted (gh exit 0).
@discardableResult
func deleteRunnerByID(scope: String, runnerID: Int) -> Bool {
    let endpoint = scope.contains("/")
        ? "repos/\(scope)/actions/runners/\(runnerID)"
        : "orgs/\(scope)/actions/runners/\(runnerID)"
    log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)")
    let args: [String] = ["api", "--method", "DELETE",
                          "-H", "Accept: application/vnd.github+json", endpoint]
    guard let data = runGHProcess(arguments: args, timeout: 30) else {
        log("deleteRunnerByID › no output (possible 204 No Content — treating as success)")
        return true
    }
    let raw = String(data: data, encoding: .utf8) ?? ""
    log("deleteRunnerByID › response=\(raw.prefix(200))")
    return true
}

/// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
/// Returns the updated label names on success, or nil on failure.
@discardableResult
func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) -> [String]? {
    let endpoint = scope.contains("/")
        ? "repos/\(scope)/actions/runners/\(runnerID)/labels"
        : "orgs/\(scope)/actions/runners/\(runnerID)/labels"
    log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)")
    guard let bodyData = try? JSONSerialization.data(withJSONObject: ["labels": labels]),
          let ghPath = ghBinaryPath()
    else {
        log("patchRunnerLabels › failed to build request")
        return nil
    }
    let task = Process()
    let outPipe = Pipe()
    task.executableURL = URL(fileURLWithPath: ghPath)
    task.arguments = ["api", "--method", "PUT",
                      "-H", "Accept: application/vnd.github+json",
                      "-H", "Content-Type: application/json",
                      "--input", "-", endpoint]
    task.standardOutput = outPipe
    task.standardError = Pipe()
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
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let raw = String(data: outData, encoding: .utf8) ?? ""
    log("patchRunnerLabels › exit=\(task.terminationStatus) response=\(raw.prefix(300))")
    guard task.terminationStatus == 0 else {
        log("patchRunnerLabels › non-zero exit for endpoint=\(endpoint)")
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

// MARK: - Token helpers

/// Fetches a short-lived runner registration token for the given scope.
func fetchRegistrationToken(scope: String) -> String? {
    let endpoint = scope.contains("/")
        ? "repos/\(scope)/actions/runners/registration-token"
        : "orgs/\(scope)/actions/runners/registration-token"
    log("fetchRegistrationToken › POSTing \(endpoint)")
    let args = ["api", "--method", "POST",
                "-H", "Accept: application/vnd.github+json", endpoint]
    guard let outputData = runGHProcess(arguments: args, timeout: 30) else {
        log("fetchRegistrationToken › no data for \(endpoint)")
        return nil
    }
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("fetchRegistrationToken › decode failed for \(endpoint) (\(outputData.count)b)")
        return nil
    }
    log("fetchRegistrationToken › got token (first 4): \(resp.token.prefix(4))...")
    return resp.token
}

/// Fetches a runner removal token for the given scope.
func fetchRemovalToken(scope: String) -> String? {
    let endpoint = scope.contains("/")
        ? "repos/\(scope)/actions/runners/remove-token"
        : "orgs/\(scope)/actions/runners/remove-token"
    log("fetchRemovalToken › POSTing \(endpoint)")
    let args = ["api", "--method", "POST",
                "-H", "Accept: application/vnd.github+json", endpoint]
    guard let outputData = runGHProcess(arguments: args, timeout: 30) else {
        log("fetchRemovalToken › no data returned for \(endpoint)")
        return nil
    }
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("fetchRemovalToken › decode failed for \(endpoint) (\(outputData.count)b)")
        return nil
    }
    log("fetchRemovalToken › got removal token (first 4): \(resp.token.prefix(4))...")
    return resp.token
}

// MARK: - POST / Cancel helpers

/// Sends a fire-and-forget POST to the given GitHub API endpoint via gh CLI.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    let args = ["api", "--method", "POST",
                "-H", "Accept: application/vnd.github+json", endpoint]
    guard let _ = runGHProcess(arguments: args, timeout: 30) else {
        log("ghPost › \(endpoint) returned no data (possible 204 — treating as success)")
        return true
    }
    log("ghPost › \(endpoint) done")
    return true
}

/// Cancels a workflow run.
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
