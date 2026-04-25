import Foundation

// MARK: - Runners

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
///   Accept: application/vnd.github.v3.raw
/// Without this header, `gh api` may return a redirect JSON object or an error
/// instead of the actual plain-text log. This was the root cause of
/// "Log not available" showing even for jobs with logs.
///
/// # Log format
/// GitHub Actions writes the full job log as one blob with step sections
/// delimited by group markers:
///
///   ##[group]Step Name
///   2024-01-01T00:00:00.0000000Z line one
///   2024-01-01T00:00:00.0000000Z line two
///   ##[endgroup]
///   ##[group]Next Step
///   ...
///
/// Each ##[group] block corresponds to one step in order.
/// stepNumber is 1-based (matches JobStep.id, which is set to idx+1 in
/// fetchActiveJobs in ActiveJob.swift).
///
/// # Fallbacks
/// - If the log has no ##[group] markers (old or very simple jobs), the full
///   cleaned log text is returned so the user always sees something.
/// - If stepNumber is out of range (e.g. log has fewer sections than the step
///   count in the API response), the full log is returned rather than nil.
///
/// # Threading
/// ⚠️ MUST be called from a background thread (DispatchQueue.global).
/// The gh CLI is a synchronous blocking child process; calling this on the
/// main thread will freeze the popover UI until the network request completes.
func fetchStepLog(jobID: Int, stepNumber: Int, scope: String) -> String? {
    // Org-scoped logs are not supported: the jobs/{id}/logs endpoint requires
    // a repo scope ("owner/repo"). Org-scoped runs do not have per-job log URLs.
    guard scope.contains("/") else {
        log("fetchStepLog › skipped: org-scoped logs not supported (scope=\(scope))")
        return nil
    }

    let gh = "/opt/homebrew/bin/gh"
    guard FileManager.default.isExecutableFile(atPath: gh) else {
        log("fetchStepLog › gh not found at \(gh)")
        return nil
    }

    let endpoint = "repos/\(scope)/actions/jobs/\(jobID)/logs"
    log("fetchStepLog › fetching \(endpoint) step=\(stepNumber)")

    // ⚠️ CRITICAL: the Accept header is required for raw text.
    // Without it: gh api returns {"message":"..."} JSON or an empty redirect.
    // With it: gh api follows the S3 redirect and streams plain-text log bytes.
    let raw = shell("\(gh) api \(endpoint) --header \"Accept: application/vnd.github.v3.raw\"")

    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty response for job \(jobID)")
        return nil
    }

    // Detect error JSON: gh api returns {"message":"..."} on 404, auth failure, etc.
    // A real log always starts with a timestamp character (digit), not ‘{’.
    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))")
        return nil
    }

    // Strip ANSI/VT100 escape sequences.
    // GitHub Actions logs contain terminal colour codes (e.g. ESC[32m for green).
    // These appear as garbage characters in a plain SwiftUI Text view.
    // Must be done BEFORE splitting into sections so markers are not obscured.
    let cleaned = stripAnsi(raw)

    // Split log into per-step sections using ##[group] as section boundaries.
    //
    // Algorithm:
    //   - Walk lines in order.
    //   - When a ##[group] line is encountered, close the current section
    //     (flush to sections array) and start a new one.
    //   - Lines before the first ##[group] (runner setup boilerplate) form
    //     section 0 and are usually empty or very short.
    //   - ##[endgroup] lines are included in the current section’s text;
    //     they are filtered out visually by being on their own line and short.
    //
    // Result: sections[0] = pre-group boilerplate, sections[1] = step 1, etc.
    // stepNumber is 1-based, so sections[stepNumber - 1] is the target.
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [String] = []
    var current: [String] = []

    for line in lines {
        if line.contains("##[group]") {
            // Flush the current accumulator as a completed section.
            // (First flush produces the pre-group boilerplate section.)
            if !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
            }
            current = [line]  // start new section with the ##[group] header line
        } else {
            current.append(line)  // accumulate into current section
        }
    }
    // Flush the final section (last step has no trailing ##[group] to trigger flush).
    if !current.isEmpty {
        sections.append(current.joined(separator: "\n"))
    }

    log("fetchStepLog › parsed \(sections.count) section(s) from log")

    // Fallback A: no ##[group] markers at all (old/simple job format).
    // Return the full cleaned log so the user sees something useful.
    if sections.isEmpty || (sections.count == 1 && !sections[0].contains("##[group]")) {
        log("fetchStepLog › no group markers, returning full raw log")
        return cleaned
    }

    // stepNumber is 1-based; sections array is 0-based.
    let index = stepNumber - 1
    guard index >= 0, index < sections.count else {
        // Fallback B: stepNumber out of range.
        // Can happen if the API step count and the log section count diverge
        // (e.g. composite actions, re-run partial steps). Return full log.
        log("fetchStepLog › stepNumber \(stepNumber) out of range (sections=\(sections.count)), returning full log")
        return cleaned
    }

    let section = sections[index]
    log("fetchStepLog › step \(stepNumber) → \(section.count)ch")
    // Return section if non-empty, otherwise fall back to full log.
    return section.isEmpty ? cleaned : section
}

/// Strip ANSI/VT100 escape sequences from a log string.
///
/// Pattern: ESC (\x1B) followed by ‘[’, then any digits/semicolons, then a letter.
/// Examples matched:
///   \x1B[32m   (set foreground green)
///   \x1B[0m    (reset)
///   \x1B[1;31m (bold red)
///   \x1B[2K    (erase line)
///
/// Uses NSRegularExpression which compiles the pattern once. The guard-let
/// will only fail if the regex literal is invalid (it never is for this pattern).
private func stripAnsi(_ input: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[A-Za-z]") else {
        // Pattern is a constant — this branch is unreachable in practice.
        return input
    }
    return regex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""  // replace each match with empty string (delete)
    )
}
