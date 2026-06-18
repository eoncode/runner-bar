// GitHubHelpers.swift
// RunnerBar
import Foundation
import os
import RunnerBarCore

// MARK: - URL helpers

// `scopeFromHtmlUrl` is defined in RunnerBarCore/Utilities/GitHubURLHelpers.swift
// and re-exported here via `RunnerBarCore` import. The previous app-target copy
// has been removed to eliminate the divergence between repo-scoped and org-scoped
// URL handling. Use `scopeFromHtmlUrl(_:)` from RunnerBarCore directly.

// MARK: - Fetch all jobs from active runs

/// Fetches all active (in-progress and queued) jobs for a given scope.
/// Supports both repo-scoped (`owner/repo`) and org-scoped (`org`) runners.
/// Date parsing goes through `ISO8601DateParser.shared` — one actor, one formatter.
func fetchActiveJobs(for scopeString: String) async -> [ActiveJob] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchActiveJobs › invalid scope: \(scopeString)")
        return []
    }
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    func runsEndpoint(status: String) -> String {
        "\(scope.apiPrefix)/actions/runs?status=\(status)&per_page=\(GitHubConstants.activeRunsPageSize)"
    }

    for status in ["in_progress", "queued"] {
        guard let data = await ghAPI(runsEndpoint(status: status)),
              let resp = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data)
        else { continue }
        // filter() cannot replace this loop: insert() mutates seenRunIDs as a side effect.
        // swiftlint:disable for_where
        for run in resp.workflowRuns {
            if seenRunIDs.insert(run.id).inserted { runIDs.append(run.id) }
        }
        // swiftlint:enable for_where
    }

    var jobs: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    for runID in runIDs {
        guard let data = await ghAPI("\(scope.apiPrefix)/actions/runs/\(runID)/jobs?per_page=\(GitHubConstants.maxPageSize)"),
              let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else { continue }
        for payload in resp.jobs {
            guard seenJobIDs.insert(payload.id).inserted else { continue }
            jobs.append(await ISO8601DateParser.shared.makeJob(from: payload, isDimmed: false))
        }
    }
    log("fetchActiveJobs › \(jobs.count) job(s) for \(scopeString)")
    return jobs
}

// MARK: - Codable helpers

/// Response envelope for the workflow runs list API endpoint.
private struct WorkflowRunsResponse: Codable {
    /// The list of workflow runs returned by the API.
    let workflowRuns: [WorkflowRun]
    /// Maps the snake_case `workflow_runs` key to the camelCase Swift property.
    enum CodingKeys: String, CodingKey {
        /// Maps `workflow_runs` JSON key to `workflowRuns`.
        case workflowRuns = "workflow_runs"
    }
}

/// Minimal workflow run payload — only the run ID is needed for job fetching.
private struct WorkflowRun: Codable {
    /// The unique run identifier.
    let id: Int
}

// MARK: - Runners

/// Fetches all registered runners for the given scope string.
func fetchRunners(for scopeString: String) async -> [Runner] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRunners › invalid scope: \(scopeString)")
        return []
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners"
    log("fetchRunners › \(endpoint)")
    guard let data = await ghAPI(endpoint) else {
        log("fetchRunners › no data for scope: \(scopeString)")
        return []
    }
    guard let response = try? JSONDecoder().decode(RunnersResponse.self, from: data) else {
        log("fetchRunners › decode failed for scope: \(scopeString)")
        return []
    }
    log("fetchRunners › found \(response.runners.count) runner(s) for \(scopeString)")
    return response.runners
}

/// Response envelope for the runners list API endpoint.
private struct RunnersResponse: Codable {
    /// The list of runners returned by the API.
    let runners: [Runner]
}

// MARK: - User orgs and repos

/// Returns the login names of all GitHub organisations the authenticated user belongs to.
func fetchUserOrgs() async -> [String] {
    guard let data = await ghAPIPaginated("\(GitHubConstants.userOrgsPath)?per_page=\(GitHubConstants.maxPageSize)") else { return [] }
    /// Minimal org payload — only the login name is needed.
    struct Org: Decodable {
        /// The organisation's GitHub login name.
        let login: String
    }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

/// Returns the `owner/repo` full names of all repositories visible to the authenticated user.
func fetchUserRepos() async -> [String] {
    guard let data = await ghAPIPaginated("\(GitHubConstants.userReposPath)?sort=updated&per_page=\(GitHubConstants.maxPageSize)") else { return [] }
    /// Minimal repo payload — only the full name is needed.
    struct Repo: Decodable {
        /// The repository's full name in `owner/repo` format.
        let fullName: String
        /// Maps the snake_case `full_name` key to the camelCase Swift property.
        enum CodingKeys: String, CodingKey {
            /// Maps `full_name` JSON key to `fullName`.
            case fullName = "full_name"
        }
    }
    guard let repos = try? JSONDecoder().decode([Repo].self, from: data) else { return [] }
    return repos.map(\.fullName)
}

// MARK: - Step log

/// Compiled regular expression for stripping ANSI escape sequences from log output.
/// Safety: NSRegularExpression is immutable after initialisation — concurrent reads are safe.
private let ansiRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

/// Fetches the log for a single step via the transport layer's `urlSessionRaw()`.
/// `urlSessionRaw` uses `application/vnd.github.v3.raw` and lets URLSession follow
/// the GitHub 302→S3 redirect automatically, eliminating the need for a manual
/// two-step redirect implementation.
func fetchStepLog(jobID: Int, stepNumber: Int, scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchStepLog › invalid scope: \(scopeString)")
        return nil
    }
    guard case .repo = scope else {
        log("fetchStepLog › skipped: org-scoped logs not supported (scope=\(scopeString))")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/jobs/\(jobID)/logs"
    log("fetchStepLog › fetching \(endpoint) step=\(stepNumber)")

    guard let data = await urlSessionRaw(endpoint) else {
        log("fetchStepLog › urlSessionRaw returned nil for job \(jobID)")
        return nil
    }
    guard let raw = String(data: data, encoding: .utf8) else {
        log("fetchStepLog › UTF-8 decode failed for job \(jobID) (\(data.count) bytes)")
        return nil
    }
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty body for job \(jobID)")
        return nil
    }
    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))")
        return nil
    }
    return parseStepLog(raw, stepNumber: stepNumber)
}

/// Parses a raw log string into sections delimited by `##[group]` markers
/// and returns the section matching `stepNumber`.
/// Falls back to the full log if sections cannot be parsed or the index is out of range.
private func parseStepLog(_ raw: String, stepNumber: Int) -> String? {
    let cleaned = stripAnsi(raw)
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [String] = []
    var current: [String] = []
    var seenGroup = false
    for line in lines {
        if line.contains("##[group]") {
            if seenGroup, !current.isEmpty { sections.append(current.joined(separator: "\n")) }
            seenGroup = true
            current = [line]
        } else if seenGroup {
            current.append(line)
        }
        // lines before the first ##[group] marker are preamble and intentionally skipped
    }
    if seenGroup, !current.isEmpty { sections.append(current.joined(separator: "\n")) }
    log("parseStepLog › parsed \(sections.count) section(s) from log")
    if sections.isEmpty {
        log("parseStepLog › no group markers, returning full raw log")
        return cleaned
    }
    let index = stepNumber - 1
    guard index >= 0, index < sections.count else {
        log(
            "parseStepLog › stepNumber \(stepNumber) out of range "
                + "(sections=\(sections.count)), returning full log"
        )
        return cleaned
    }
    let section = sections[index]
    log("parseStepLog › step \(stepNumber) → \(section.count)ch")
    return section.isEmpty ? cleaned : section
}

/// Strips ANSI escape codes from a raw log string.
private func stripAnsi(_ input: String) -> String {
    guard let ansiRegex else { return input }
    return ansiRegex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""
    )
}
