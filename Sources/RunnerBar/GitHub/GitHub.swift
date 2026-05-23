// GitHub.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - URL helpers

/// Performs the scopeFromHtmlUrl operation.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3
    else { return nil }
    let components = url.pathComponents
    return "\(components[1])/\(components[2])"
}

/// Performs the runIDFromHtmlUrl operation.
func runIDFromHtmlUrl(_ url: String?) -> Int? {
    guard let url else { return nil }
    let parts = url.components(separatedBy: "/")
    for (idx, part) in parts.enumerated() {
        if part == "runs", idx + 1 < parts.count {
            return Int(parts[idx + 1])
        }
    }
    return nil
}

// MARK: - Fetch all jobs from active runs

/// Shared ISO-8601 date formatter.
/// ISO8601DateFormatter is expensive to allocate (loads ICU calendars);
/// keeping one file-level instance avoids repeated allocation on every fetch call.
private let iso8601 = ISO8601DateFormatter()

/// Performs the fetchActiveJobs operation.
/// Supports both repo-scoped (`owner/repo`) and org-scoped (`org`) runners.
/// `scope.apiPrefix` produces the correct `/repos/{owner}/{repo}` or `/orgs/{org}`
/// prefix for all downstream API calls — no per-scope branching needed here.
func fetchActiveJobs(for scopeString: String) -> [ActiveJob] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchActiveJobs › invalid scope: \(scopeString)")
        return []
    }
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    func runsEndpoint(status: String) -> String {
        "\(scope.apiPrefix)/actions/runs?status=\(status)&per_page=50"
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
        // NOTE: No scope-type guard here — both .repo and .org are supported.
        // scope.apiPrefix already returns the correct /repos/{owner}/{repo} or
        // /orgs/{org} prefix. Filtering to .repo only was the #774 bug.
        guard let data = ghAPI("\(scope.apiPrefix)/actions/runs/\(runID)/jobs?per_page=100"),
              let resp = try? JSONDecoder().decode(JobsResponse.self, from: data)
        else { continue }
        for payload in resp.jobs {
            guard seenJobIDs.insert(payload.id).inserted else { continue }
            jobs.append(makeActiveJob(from: payload, iso: iso8601, isDimmed: false))
        }
    }
    log("fetchActiveJobs › \(jobs.count) job(s) for \(scopeString)")
    return jobs
}

// MARK: - Codable helpers

/// A value type representing WorkflowRunsResponse.
private struct WorkflowRunsResponse: Codable {
    /// The workflowRuns constant.
    let workflowRuns: [WorkflowRun]
    /// UserDefaults key constants.
    enum CodingKeys: String, CodingKey {
        /// Coding key mapping to the `workflowRuns` JSON field.
        case workflowRuns = "workflow_runs"
    }
}

/// A value type representing WorkflowRun.
private struct WorkflowRun: Codable {
    /// The `id` property.
    let id: Int
}

// MARK: - Runners

/// Performs the fetchRunners operation.
func fetchRunners(for scopeString: String) -> [Runner] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRunners › invalid scope: \(scopeString)")
        return []
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners"
    log("fetchRunners › \(endpoint)")
    guard let data = ghAPI(endpoint) else {
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

/// A value type representing RunnersResponse.
private struct RunnersResponse: Codable {
    /// The `runners` property.
    let runners: [Runner]
}

// MARK: - User orgs and repos

/// Performs the fetchUserOrgs operation.
func fetchUserOrgs() -> [String] {
    guard let data = ghAPIPaginated("/user/orgs?per_page=100") else { return [] }
    struct Org: Decodable { let login: String }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

/// Performs the fetchUserRepos operation.
func fetchUserRepos() -> [String] {
    guard let data = ghAPIPaginated("/user/repos?per_page=100&sort=updated") else { return [] }
    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    guard let repos = try? JSONDecoder().decode([Repo].self, from: data) else { return [] }
    return repos.map(\.fullName)
}

// MARK: - Step log

// swiftlint:disable:next force_try missing_docs
private let _ansiRegex = try! NSRegularExpression( // Compiled once; literal pattern never fails.
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

/// URLSession configured to NOT follow redirects.
/// Used for the first leg of fetchStepLog so we can capture the pre-signed S3
/// Location URL from the GitHub 302 response before fetching the log body.
private class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil) // Cancel the redirect; we want the 302 Location header.
    }
}
private let noRedirectDelegate = NoRedirectDelegate()
private let noRedirectSession = URLSession(
    configuration: .default,
    delegate: noRedirectDelegate,
    delegateQueue: nil
)

/// Fetches step logs for a given job via URLSession (token path) or gh CLI (fallback).
///
/// The GitHub `/actions/jobs/{id}/logs` endpoint returns a **302 redirect** to a
/// pre-signed S3 URL. We handle this in two steps:
/// 1. Issue a GET with redirects disabled to capture the `Location` header.
/// 2. Fetch the raw log from the S3 URL without `Authorization` headers
///    (pre-signed URLs reject extra auth headers with a 400 SignatureDoesNotMatch error).
///
/// Falls back to `runGHProcess` when no token is available.
func fetchStepLog(jobID: Int, stepNumber: Int, scope scopeString: String) -> String? {
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

    let raw: String?
    if let token = githubToken() {
        raw = fetchStepLogViaURLSession(endpoint: endpoint, token: token)
    } else {
        log("fetchStepLog › no token, falling back to gh CLI")
        raw = fetchStepLogViaCLI(endpoint: endpoint)
    }

    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty response for job \(jobID)")
        return nil
    }
    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))")
        return nil
    }
    return parseStepLog(raw, stepNumber: stepNumber)
}

/// Step 1+2: resolve the 302 redirect then fetch the raw log body.
private func fetchStepLogViaURLSession(endpoint: String, token: String) -> String? {
    let urlString = endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    guard let url = URL(string: urlString) else {
        log("fetchStepLogViaURLSession › invalid URL: \(urlString)")
        return nil
    }

    // Step 1: GET with redirects disabled — capture the Location header.
    var redirectURL: URL?
    var step1Request = URLRequest(url: url, timeoutInterval: 20)
    step1Request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    step1Request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    step1Request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    let sem1 = DispatchSemaphore(value: 0)
    noRedirectSession.dataTask(with: step1Request) { _, response, error in
        defer { sem1.signal() }
        if let error {
            log("fetchStepLogViaURLSession › step1 error: \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse {
            log("fetchStepLogViaURLSession › step1 status=\(http.statusCode)")
            if let location = http.value(forHTTPHeaderField: "Location"),
               let locURL = URL(string: location) {
                redirectURL = locURL
            }
        }
    }.resume()
    sem1.wait()

    guard let s3URL = redirectURL else {
        log("fetchStepLogViaURLSession › no Location header, falling back to CLI")
        return nil
    }

    // Step 2: Fetch the raw log from the pre-signed S3 URL.
    // Do NOT send Authorization header — pre-signed URLs use their own signature
    // and reject extra auth headers with 400 SignatureDoesNotMatch.
    let sem2 = DispatchSemaphore(value: 0)
    var logData: Data?
    var plainRequest = URLRequest(url: s3URL, timeoutInterval: 30)
    plainRequest.setValue("text/plain", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: plainRequest) { data, response, error in
        defer { sem2.signal() }
        if let error {
            log("fetchStepLogViaURLSession › step2 error: \(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse {
            log("fetchStepLogViaURLSession › step2 status=\(http.statusCode)")
            guard (200..<300).contains(http.statusCode) else { return }
        }
        logData = data
    }.resume()
    sem2.wait()

    guard let data = logData else { return nil }
    return String(data: data, encoding: .utf8)
}

/// CLI fallback for token-less configurations.
private func fetchStepLogViaCLI(endpoint: String) -> String? {
    let (data, _) = runGHProcess(
        arguments: ["api", endpoint, "--header", "Accept: application/vnd.github.v3.raw"],
        timeout: 30
    )
    guard let data else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Parses a raw log string into sections and returns the section for `stepNumber`.
private func parseStepLog(_ raw: String, stepNumber: Int) -> String? {
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
    log("parseStepLog › parsed \(sections.count) section(s) from log")
    if sections.isEmpty || (sections.count == 1 && !sections[0].contains("##[group]")) {
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

/// Performs the stripAnsi operation.
private func stripAnsi(_ input: String) -> String {
    _ansiRegex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""
    )
}
