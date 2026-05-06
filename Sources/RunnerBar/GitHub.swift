import Foundation

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
    guard let data = json.data(using: .utf8),
          let response = try? JSONDecoder().decode(RunnersResponse.self, from: data)
    else {
        log("fetchRunners › decode failed for scope: \(scope)")
        return []
    }
    log("fetchRunners › found \(response.runners.count) runner(s) for \(scope)")
    return response.runners
}

private struct RunnersResponse: Codable {
    let runners: [Runner]
}

// MARK: - Step log

/// Fetch and slice the raw log for a single step.
///
/// # GitHub API details
/// Endpoint: GET /repos/{owner}/{repo}/actions/jobs/{job_id}/logs
/// This endpoint returns a 302 redirect to a short-lived pre-signed AWS S3 URL.
/// The `gh api` CLI follows the redirect automatically.
///
/// Accept header MUST be:
/// Accept: application/vnd.github.v3.raw
/// Without this header, `gh api` may return a redirect JSON object or an error
/// instead of the actual plain-text log. This was the root cause of
/// "Log not available" showing even for jobs with logs.
///
/// # Log format
/// GitHub Actions writes the full job log as one blob with step sections
/// delimited by group markers:
///
/// ##[group]Step Name
/// 2024-01-01T00:00:00.0000000Z line one
/// ...
/// ##[endgroup]
///
/// Each ##[group] block corresponds to one step in order.
/// stepNumber is 1-based (matches JobStep.id, idx+1 in fetchActiveJobs).
///
/// # Fallbacks
/// - If the log has no ##[group] markers, the full cleaned log text is returned.
/// - If stepNumber is out of range, the full log is returned rather than nil.
///
/// # Threading
/// ⚠️ MUST be called from a background thread (DispatchQueue.global).
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    // Org-scoped logs are not supported: the jobs/{id}/logs endpoint requires
    // a repo scope ("owner/repo").
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
    // ⚠️ CRITICAL: the Accept header is required for raw text.
    // Without it: gh api returns JSON or an empty redirect.
    let raw = shell("\(ghPath) api \(endpoint) --header \"Accept: application/vnd.github.v3.raw\"")
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty response for job \(jobID)")
        return nil
    }
    // Detect error JSON: gh api returns {"message":"..."} on 404, auth failure, etc.
    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))")
        return nil
    }
    // Strip ANSI/VT100 escape sequences before splitting into sections.
    let cleaned = stripAnsi(raw)
    // Split log into per-step sections using ##[group] as section boundaries.
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
    // Fallback A: no ##[group] markers at all.
    if sections.isEmpty || (sections.count == 1 && !sections[0].contains("##[group]")) {
        log("fetchStepLog › no group markers, returning full raw log")
        return cleaned
    }
    // stepNumber is 1-based; sections array is 0-based.
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

/// Strip ANSI/VT100 escape sequences from a log string.
/// Pattern: ESC (\x1B) followed by '[', then any digits/semicolons, then a letter.
private func stripAnsi(_ input: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\u001B\\[[0-9;]*[A-Za-z]") else {
        // Pattern is a constant — this branch is unreachable in practice.
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
/// Covers Apple Silicon Homebrew (/opt/homebrew), Intel Homebrew (/usr/local), and system (/usr/bin).
func ghBinaryPath() -> String? {
    let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

// MARK: - POST helper

/// Fires a POST to the GitHub API via `gh api --method POST`.
/// Returns true if gh exits 0 (HTTP 2xx), false otherwise.
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
    let timeout = DispatchWorkItem { task.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
    task.waitUntilExit()
    timeout.cancel()
    log("ghPost › \(endpoint) exit \(task.terminationStatus)")
    return task.terminationStatus == 0
}

// MARK: - Cancel run

/// Cancels a workflow run via POST .../cancel.
/// Returns true on HTTP 202 (accepted), false on error or 409 (already completed).
/// Must be called from a background thread.
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
