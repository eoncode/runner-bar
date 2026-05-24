// GitHub.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - URL helpers

/// Extracts the `owner/repo` scope string from a GitHub HTML URL.
/// Returns `nil` if the URL is malformed or has fewer than 3 path components.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3
    else { return nil }
    let components = url.pathComponents
    return "\(components[1])/\(components[2])"
}

// MARK: - Fetch all jobs from active runs

/// Shared ISO-8601 date formatter.
private let iso8601 = ISO8601DateFormatter()

/// Fetches all active (in-progress and queued) jobs for a given scope.
/// Supports both repo-scoped (`owner/repo`) and org-scoped (`org`) runners.
func fetchActiveJobs(for scopeString: String) -> [ActiveJob] {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchActiveJobs › invalid scope: \(scopeString)")
        return []
    }
    var runIDs: [Int] = []
    var seenRunIDs = Set<Int>()

    /// Returns the API endpoint for workflow runs filtered by the given status.
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

/// Response envelope for the workflow runs list API endpoint.
private struct WorkflowRunsResponse: Codable {
    /// The list of workflow runs returned by the API.
    let workflowRuns: [WorkflowRun]
    /// Maps the snake_case API key to the camelCase Swift property.
    enum CodingKeys: String, CodingKey {
        /// The workflowRuns coding key.
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

/// Response envelope for the runners list API endpoint.
private struct RunnersResponse: Codable {
    /// The list of runners returned by the API.
    let runners: [Runner]
}

// MARK: - User orgs and repos

/// Returns the login names of all GitHub organisations the authenticated user belongs to.
func fetchUserOrgs() -> [String] {
    guard let data = ghAPIPaginated("/user/orgs?per_page=100") else { return [] }
    struct Org: Decodable { let login: String }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

/// Returns the `owner/repo` full names of all repositories visible to the authenticated user.
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

// swiftlint:disable:next force_try
/// Compiled regular expression for stripping ANSI escape sequences from log output.
private let _ansiRegex = try! NSRegularExpression( // swiftlint:disable:this force_try
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

// URLSession configured to NOT follow redirects.
// Used for the first leg of fetchStepLog so we can capture the pre-signed S3
// Location URL from the GitHub 302 response before fetching the log body.
// Lifetime: module-level singleton — allocated once at app start, shared for
// the process lifetime. URLSession is thread-safe and designed for reuse.
/// `URLSessionTaskDelegate` that prevents automatic redirect following.
/// Captures the `Location` header from GitHub's 302 response so the caller
/// can fetch the pre-signed S3 URL directly.
private class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    /// Intercepts redirect responses and calls the completion handler with `nil`
    /// to prevent URLSession from following the redirect automatically.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session; _ = task; _ = response; _ = request
        completionHandler(nil)
    }
}

/// Module-level `NoRedirectDelegate` singleton.
private let noRedirectDelegate = NoRedirectDelegate()
/// URLSession that never follows HTTP redirects — used for step-1 of `fetchStepLogViaURLSession`.
private let noRedirectSession = URLSession(
    configuration: .default,
    delegate: noRedirectDelegate,
    delegateQueue: nil
)

/// Fetches step logs via URLSession (token path) or gh CLI (fallback).
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
        // TODO: migrate sem1/sem2 to async/await as part of #777
        raw = fetchStepLogViaURLSession(endpoint: endpoint, token: token)
            ?? fetchStepLogViaCLI(endpoint: endpoint)
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
/// Returns `nil` if step 1 does not yield a Location header (caller falls back to CLI).
private func fetchStepLogViaURLSession(endpoint: String, token: String) -> String? {
    let urlString = endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    guard let url = URL(string: urlString) else {
        log("fetchStepLogViaURLSession › invalid URL: \(urlString)")
        return nil
    }

    var redirectURL: URL?
    var step1Request = URLRequest(url: url, timeoutInterval: 20)
    step1Request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    step1Request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    step1Request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    let sem1 = DispatchSemaphore(value: 0) // TODO: #777 async/await
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
        log("fetchStepLogViaURLSession › no Location header, returning nil for CLI fallback")
        return nil
    }

    let sem2 = DispatchSemaphore(value: 0) // TODO: #777 async/await
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

/// Fetches raw step log text using the `gh` CLI as a fallback.
private func fetchStepLogViaCLI(endpoint: String) -> String? {
    let (data, _) = runGHProcess(
        arguments: ["api", endpoint, "--header", "Accept: application/vnd.github.v3.raw"],
        timeout: 30
    )
    guard let data else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Parses a raw log string into sections delimited by `##[group]` markers
/// and returns the section matching `stepNumber`.
/// Falls back to the full log if sections cannot be parsed or the index is out of range.
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

/// Strips ANSI escape codes from a raw log string.
private func stripAnsi(_ input: String) -> String {
    _ansiRegex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""
    )
}
