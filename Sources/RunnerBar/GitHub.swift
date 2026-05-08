// swiftlint:disable file_length
import Foundation

// MARK: - Rate limit flag

/// Set to `true` when any API call receives a 403/429 rate-limit response.
/// Reset to `false` at the start of each `RunnerStore.fetch()` poll cycle.
/// Intentionally non-atomic: a one-cycle lag in the UI warning is acceptable.
var ghIsRateLimited: Bool = false

// MARK: - URLSession helpers

/// Base URL for the GitHub REST API.
private let gitHubAPIBase = "https://api.github.com"

/// Builds an authenticated `URLRequest` for the given GitHub API endpoint.
/// Adds `Authorization: Bearer <token>` when a token is available.
private func gitHubRequest(
    _ endpoint: String,
    method: String = "GET"
) -> URLRequest? {
    let path = endpoint.hasPrefix("http") ? endpoint
        : "\(gitHubAPIBase)/\(endpoint.hasPrefix("/") ? String(endpoint.dropFirst()) : endpoint)"
    guard let url = URL(string: path) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpMethod = method
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    if let token = githubToken() {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return req
}

/// Performs a synchronous (blocking) GET against the GitHub REST API.
/// Returns raw `Data` on HTTP 2xx, `nil` on network error or 401/403/404/429.
/// Must only be called from a background thread.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard var req = gitHubRequest(endpoint) else {
        log("ghAPI › could not build URL for: \(endpoint)")
        return nil
    }
    req.timeoutInterval = timeout
    return performSyncRequest(req, label: "ghAPI", endpoint: endpoint)
}

/// Performs a synchronous paginated GET, following GitHub `Link: rel="next"` headers.
/// Concatenates all pages into a single JSON array. Returns `nil` on first-page failure.
/// Must only be called from a background thread.
func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    return performFullPaginatedGET(endpoint, timeout: timeout)
}

/// Full paginated GET that correctly captures `Link` response headers per page.
private func performFullPaginatedGET(_ endpoint: String, timeout: TimeInterval) -> Data? {
    var allItems: [[String: Any]] = []
    var nextURL: String? = endpoint
    while let current = nextURL {
        nextURL = nil
        guard var req = gitHubRequest(current) else { break }
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var pageData: Data?
        var linkHeader: String?
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                log("ghAPIPaginated › network error: \(error)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            linkHeader = http.value(forHTTPHeaderField: "Link")
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 403 || http.statusCode == 429 {
                    ghIsRateLimited = true
                    log("ghAPIPaginated › rate limit (\(http.statusCode)): \(current)")
                }
                return
            }
            pageData = data
        }
        task.resume()
        sem.wait()
        guard let data = pageData else { break }
        if let page = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            allItems.append(contentsOf: page)
        }
        nextURL = parseLinkNext(linkHeader)
    }
    return allItems.isEmpty ? nil : encodeArray(allItems)
}

/// Parses the `Link` response header and returns the `rel="next"` URL, if any.
private func parseLinkNext(_ header: String?) -> String? {
    guard let header else { return nil }
    // Format: <https://api.github.com/...?page=2>; rel="next", <...>; rel="last"
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard segments.count >= 2,
              segments[1].contains("rel=\"next\""),
              let urlPart = segments.first,
              urlPart.hasPrefix("<"), urlPart.hasSuffix(">")
        else { continue }
        return String(urlPart.dropFirst().dropLast())
    }
    return nil
}

/// Encodes an array of dictionaries back to JSON `Data`.
private func encodeArray(_ items: [[String: Any]]) -> Data? {
    try? JSONSerialization.data(withJSONObject: items)
}

/// Synchronous blocking HTTP request. Signals a semaphore to unblock the calling thread.
/// Returns `Data` on HTTP 2xx, `nil` otherwise. Must only be called from a background thread.
private func performSyncRequest(
    _ request: URLRequest,
    label: String,
    endpoint: String
) -> Data? {
    let sem = DispatchSemaphore(value: 0)
    var result: Data?
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("\(label) › network error: \(error)")
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        log("\(label) › \(endpoint) → HTTP \(http.statusCode) \(data?.count ?? 0)b")
        if http.statusCode == 403 || http.statusCode == 429 {
            ghIsRateLimited = true
            log("\(label) › rate limit (\(http.statusCode)): \(endpoint)")
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            log("\(label) › non-2xx (\(http.statusCode)): \(endpoint)")
            return
        }
        result = data
    }
    task.resume()
    sem.wait()
    return result
}

// MARK: - URL helpers

/// Extracts the "owner/repo" scope from a GitHub Actions job HTML URL.
func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString),
          url.pathComponents.count >= 3
    else { return nil }
    let components = url.pathComponents
    return "\(components[1])/\(components[2])"
}

/// Extracts the workflow run ID from a GitHub Actions job HTML URL.
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

/// Fetches all active (in_progress + queued) jobs across all runs for the given scope.
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
        guard
            let data = ghAPI(runsEndpoint(status: status)),
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
        guard
            let data = ghAPI("repos/\(scope)/actions/runs/\(runID)/jobs?per_page=100"),
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

/// Fetches all self-hosted runners for the given scope via the GitHub REST API.
func fetchRunners(for scope: String) -> [Runner] {
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners"
    } else {
        endpoint = "orgs/\(scope)/actions/runners"
    }
    log("fetchRunners › \(endpoint)")
    guard
        let data = ghAPI(endpoint),
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

// MARK: - User orgs and repos (Phase 3)

/// Returns the login names of all organisations the authenticated user belongs to.
/// Follows Link rel=next pagination to return all orgs.
/// Returns an empty array on error or if unauthenticated.
func fetchUserOrgs() -> [String] {
    guard let data = ghAPIPaginated("/user/orgs?per_page=100") else { return [] }
    struct Org: Decodable { let login: String }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

/// Returns `owner/repo` strings for the authenticated user's repositories,
/// sorted by most recently updated.
/// Returns an empty array on error or if unauthenticated.
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

/// Fetches a runner registration token for the given scope via URLSession POST.
/// - Repo-scoped: `POST /repos/{owner}/{repo}/actions/runners/registration-token`
/// - Org-scoped:  `POST /orgs/{org}/actions/runners/registration-token`
///
/// Returns the `token` string on success, `nil` on API error or missing auth.
/// ⚠️ Blocking — must only be called from a background thread.
func fetchRegistrationToken(scope: String) -> String? {
    let endpoint: String
    if scope.contains("/") {
        endpoint = "repos/\(scope)/actions/runners/registration-token"
    } else {
        endpoint = "orgs/\(scope)/actions/runners/registration-token"
    }
    guard var req = gitHubRequest(endpoint, method: "POST") else {
        log("fetchRegistrationToken › could not build request")
        return nil
    }
    req.timeoutInterval = 30
    let sem = DispatchSemaphore(value: 0)
    var result: String?
    let task = URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("fetchRegistrationToken › network error: \(error)")
            return
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let data
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            log("fetchRegistrationToken › HTTP \(code) for \(endpoint)")
            return
        }
        struct TokenResponse: Decodable { let token: String }
        if let resp = try? JSONDecoder().decode(TokenResponse.self, from: data) {
            result = resp.token
        } else {
            log("fetchRegistrationToken › decode failed: " +
                "\(String(data: data, encoding: .utf8)?.prefix(120) ?? "")")
        }
    }
    task.resume()
    sem.wait()
    log("fetchRegistrationToken › \(endpoint) token=\(result != nil)")
    return result
}

// MARK: - Step log

/// Fetch and slice the raw log for a single step.
///
/// Retained as a gh-CLI call: raw log streaming via `Accept: application/vnd.github.v3.raw`
/// is awkward with URLSession (redirects, chunked encoding) and gh handles it cleanly.
///
/// ⚠️ Returns `nil` for users who authenticate via OAuth only (no `gh` installed).
/// Follow-up migration to URLSession tracked in #336.
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
    guard let regex = try? NSRegularExpression(pattern: "\u001B\\[[0-9;]*[A-Za-z]") else {
        return input
    }
    return regex.stringByReplacingMatches(
        in: input,
        range: NSRange(input.startIndex..., in: input),
        withTemplate: ""
    )
}

// MARK: - gh binary path (used by fetchStepLog only)

/// Returns the first executable `gh` binary found on common install paths.
/// Used only by `fetchStepLog` for raw log streaming via `gh api --header`.
func ghBinaryPath() -> String? {
    let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

// MARK: - POST helper

/// Fires a POST to the GitHub REST API via URLSession.
/// Returns `true` on HTTP 2xx, `false` otherwise.
/// Must be called from a background thread.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    guard var req = gitHubRequest(endpoint, method: "POST") else {
        log("ghPost › could not build request for: \(endpoint)")
        return false
    }
    req.timeoutInterval = 30
    let sem = DispatchSemaphore(value: 0)
    var success = false
    let task = URLSession.shared.dataTask(with: req) { _, response, error in
        defer { sem.signal() }
        if let error {
            log("ghPost › network error: \(error)")
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        log("ghPost › \(endpoint) HTTP \(http.statusCode)")
        success = (200..<300).contains(http.statusCode)
    }
    task.resume()
    sem.wait()
    return success
}

// MARK: - Cancel run

/// Cancels a workflow run via POST `.../cancel`.
/// Returns `true` on HTTP 202, `false` on error or 409 (already completed).
/// Must be called from a background thread.
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
// swiftlint:enable file_length
