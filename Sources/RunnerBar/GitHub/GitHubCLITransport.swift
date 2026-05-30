// GitHubCLITransport.swift
// RunnerBar
import Foundation

// MARK: - gh CLI subprocess transport
//
// All functions in this file call the `gh` CLI binary via Process.
// runGHProcess() is the shared primitive; all other functions use it.
// The underlying process management is handled by ProcessRunner.

// MARK: - Shared gh binary path

/// Returns the path to the `gh` CLI binary, or nil if not found.
///
/// Runs `gh` with the given arguments. Returns (output, exitCode).
/// output is nil when the process produces no stdout (e.g. HTTP 204 No Content).
/// exitCode is Int32.max on launch failure.
/// Pass `stdin` to write data to the process's standard input (e.g. for `--input -`).
func runGHProcess(
    arguments: [String],
    stdin: Data? = nil,
    timeout: TimeInterval = 20
) -> (data: Data?, exitCode: Int32) {
    guard let ghPath = GHBinaryLocator.ghBinaryPath() else {
        log("runGHProcess › gh not found in known paths")
        return (nil, Int32.max)
    }
    log("runGHProcess › \(ghPath) \(arguments.joined(separator: " "))")
    let result = ProcessRunner.run(
        executableURL: URL(fileURLWithPath: ghPath),
        arguments: arguments,
        stdin: stdin,
        timeout: timeout
    )
    return (result.data, result.exitCode)
}

// MARK: - Rate limit helpers

/// Returns true only when a gh CLI JSON error body indicates a real rate-limit.
///
/// GitHub uses HTTP 403 for both permission errors and rate-limits.
/// A permission 403 has a message like "Must have admin rights to Repository."
/// A rate-limit 403 has a message containing "rate limit" or "secondary rate".
/// HTTP 429 is always a rate limit regardless of the message body.
private func isCLIRateLimit(status: String, json: [String: Any]) -> Bool {
    if status == "429" { return true }
    guard status == "403" else { return false }
    let message = (json["message"] as? String ?? "").lowercased()
    let isRateLimit = message.contains("rate limit") || message.contains("secondary rate")
    if !isRateLimit {
        log("ghCLI › 403 is a PERMISSION ERROR (not a rate limit) — NOT setting ghIsRateLimited. message='\(json["message"] as? String ?? "")'")
    }
    return isRateLimit
}

// MARK: - CLI API wrappers

/// Performs the ghAPICLI operation.
func ghAPICLI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    let (outputData, _) = runGHProcess(arguments: ["api", endpoint], timeout: timeout)
    guard let outputData else { return nil }
    log("ghAPICLI › \(endpoint) → \(outputData.count)b")
    if let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
       let status = json["status"] as? String {
        if isCLIRateLimit(status: status, json: json) {
            ghIsRateLimited = true
            log("ghAPICLI › rate limit (\(status)): \(endpoint)")
            return nil
        } else if status == "403" || status == "404" {
            log("ghAPICLI › permission/not-found error (\(status)): \(endpoint) — not setting ghIsRateLimited")
            return nil
        }
    }
    return outputData
}

/// Performs the ghAPIPaginatedCLI operation.
func ghAPIPaginatedCLI(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    let (outputData, exitCode) = runGHProcess(
        arguments: ["api", "--paginate", endpoint],
        timeout: timeout
    )
    if exitCode != 0 {
        let raw = outputData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let rawLower = raw.lowercased()
        // Only treat as rate-limit when the output explicitly mentions rate limiting.
        // A bare "403" in the output is a permission error, not a rate limit.
        let isRateLimit = rawLower.contains("rate limit")
            || rawLower.contains("secondary rate")
            || rawLower.contains("\"429\"")
        if isRateLimit {
            ghIsRateLimited = true
            log("ghAPIPaginatedCLI › rate limit detected: \(endpoint)")
        } else {
            log("ghAPIPaginatedCLI › non-zero exit (\(exitCode)) — permission error or other failure, NOT setting ghIsRateLimited: \(endpoint)")
            if !raw.isEmpty { log("ghAPIPaginatedCLI › output preview: \(raw.prefix(300))") }
        }
        return nil
    }
    log("ghAPIPaginatedCLI › \(endpoint) → \(outputData?.count ?? 0)b")
    return outputData
}

// MARK: - Runner mutation helpers

/// Directly deregisters a runner from GitHub via DELETE API.
/// Returns true if gh exited 0 (success) or produced no output (HTTP 204 No Content).
/// Returns false if gh failed to launch, timed out, or exited non-zero with output.
@discardableResult
func deleteRunnerByID(scope scopeString: String, runnerID: Int) -> Bool {
    guard let scope = Scope.parse(scopeString) else {
        log("deleteRunnerByID › invalid scope: \(scopeString)")
        return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)"
    log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)")
    let args: [String] = ["api", "--method", "DELETE",
                          "-H", "Accept: application/vnd.github+json", endpoint]
    let (data, exitCode) = runGHProcess(arguments: args, timeout: 30)
    if let data {
        let raw = String(data: data, encoding: .utf8) ?? ""
        log("deleteRunnerByID › response=\(raw.prefix(200))")
    } else {
        log("deleteRunnerByID › no output (HTTP 204 No Content)")
    }
    let success = exitCode == 0
    if !success { log("deleteRunnerByID › failed exit=\(exitCode)") }
    return success
}

/// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
/// Returns the updated label names on success, or nil on failure.
@discardableResult
func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) -> [String]? {
    guard let scope = Scope.parse(scopeString) else {
        log("patchRunnerLabels › invalid scope: \(scopeString)")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
    log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)")
    guard let bodyData = try? JSONSerialization.data(withJSONObject: ["labels": labels])
    else { log("patchRunnerLabels › failed to serialise request body"); return nil }
    let args: [String] = ["api", "--method", "PUT",
                          "-H", "Accept: application/vnd.github+json",
                          "-H", "Content-Type: application/json",
                          "--input", "-", endpoint]
    let (outData, exitCode) = runGHProcess(arguments: args, stdin: bodyData, timeout: 30)
    let raw = outData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    log("patchRunnerLabels › exit=\(exitCode) response=\(raw.prefix(300))")
    guard exitCode == 0, let outData else {
        log("patchRunnerLabels › non-zero exit or no data for endpoint=\(endpoint)")
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
func fetchRegistrationToken(scope scopeString: String) -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRegistrationToken › invalid scope: \(scopeString)")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/registration-token"
    log("fetchRegistrationToken › POSTing \(endpoint)")
    let args = ["api", "--method", "POST", "-H", "Accept: application/vnd.github+json", endpoint]
    let (outputData, _) = runGHProcess(arguments: args, timeout: 30)
    guard let outputData else { log("fetchRegistrationToken › no data for \(endpoint)"); return nil }
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("fetchRegistrationToken › decode failed for \(endpoint) (\(outputData.count)b)")
        return nil
    }
    log("fetchRegistrationToken › got registration token")
    return resp.token
}

/// Fetches a runner removal token for the given scope.
func fetchRemovalToken(scope scopeString: String) -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRemovalToken › invalid scope: \(scopeString)")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/remove-token"
    log("fetchRemovalToken › POSTing \(endpoint)")
    let args = ["api", "--method", "POST", "-H", "Accept: application/vnd.github+json", endpoint]
    let (outputData, _) = runGHProcess(arguments: args, timeout: 30)
    guard let outputData else { log("fetchRemovalToken › no data returned for \(endpoint)"); return nil }
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("fetchRemovalToken › decode failed for \(endpoint) (\(outputData.count)b)")
        return nil
    }
    log("fetchRemovalToken › got removal token")
    return resp.token
}

// MARK: - POST / Cancel helpers

/// Sends a POST to the given GitHub API endpoint via gh CLI.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    let args = ["api", "--method", "POST", "-H", "Accept: application/vnd.github+json", endpoint]
    let (_, exitCode) = runGHProcess(arguments: args, timeout: 30)
    let success = exitCode == 0
    log("ghPost › \(endpoint) success=\(success) exit=\(exitCode)")
    return success
}

/// Cancels a workflow run.
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
