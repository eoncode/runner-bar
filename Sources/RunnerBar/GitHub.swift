import Foundation

// MARK: - Runners

/// Fetches the list of runners for a given scope (repo or org).
func fetchRunners(for scope: String) -> [Runner] {
    let path = scope.contains("/") ? "/repos/\(scope)/actions/runners" : "/orgs/\(scope)/actions/runners"

    log("fetchRunners › \(path)")
    let json = shell("/opt/homebrew/bin/gh api \(path)")
    log("fetchRunners › response prefix: \(json.prefix(120))")

    guard let data = json.data(using: .utf8),
          let response = try? JSONDecoder().decode(RunnersResponse.self, from: data) else {
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
/// # Threading
/// ⚠️ MUST be called from a background thread (DispatchQueue.global).
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

    let raw = shell("\(ghPath) api \(endpoint) --header \"Accept: application/vnd.github.v3.raw\"")
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty response for job \(jobID)")
        return nil
    }

    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))")
        return nil
    }

    let cleaned = stripAnsi(raw)
    let sections = parseLogSections(cleaned)

    if sections.isEmpty || (sections.count == 1 && !sections[0].contains("##[group]")) {
        log("fetchStepLog › no group markers, returning full raw log")
        return cleaned
    }

    let idx = stepNumber - 1
    guard idx >= 0, idx < sections.count else {
        log("fetchStepLog › stepNumber \(stepNumber) out of range (sections=\(sections.count)), returning full log")
        return cleaned
    }

    let section = sections[idx]
    log("fetchStepLog › step \(stepNumber) → \(section.count)ch")
    return section.isEmpty ? cleaned : section
}

/// Splits a raw log into sections based on ##[group] markers.
private func parseLogSections(_ cleaned: String) -> [String] {
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [String] = []
    var current: [String] = []

    for line in lines {
        if line.contains("##[group]") {
            if !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
            }
            current = [line]
        } else {
            current.append(line)
        }
    }
    if !current.isEmpty {
        sections.append(current.joined(separator: "\n"))
    }
    return sections
}

/// Strip ANSI/VT100 escape sequences from a log string.
private func stripAnsi(_ input: String) -> String {
    let pattern = "\\x1B\\[[0-9;]*[A-Za-z]"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
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
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    guard let ghPath = ghBinaryPath() else {
        log("ghPost › gh not found")
        return false
    }
    let task = Process()
    task.executableURL  = URL(fileURLWithPath: ghPath)
    task.arguments      = ["api", "--method", "POST",
                           "-H", "Accept: application/vnd.github+json",
                           endpoint]
    task.standardOutput = Pipe()
    task.standardError  = Pipe()
    do { try task.run() } catch {
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
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
