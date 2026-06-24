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
