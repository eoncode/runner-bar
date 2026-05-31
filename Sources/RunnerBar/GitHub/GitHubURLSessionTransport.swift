// GitHubURLSessionTransport.swift
// RunnerBar
@preconcurrency import Foundation
import os

// MARK: - Rate limit flag

/// Combined rate-limit state held under a single lock.
///
/// Both `isLimited` and `resetDate` are mutated together so that a reader
/// can never observe `isLimited == true` with a stale / nil `resetDate`.
///
/// Pipeline:
///   1. `urlSessionAPI` / `urlSessionAPIPaginated` receive a 403/429.
///   2. They write `isLimited = true` + `resetDate` under this lock and call
///      `scheduleRateLimitReset(resetAt:)` to auto-clear after the window.
///   3. `ghIsRateLimited` / `ghRateLimitResetDate` module vars expose the
///      current values for consumption on any thread.
///   4. `RunnerStore.applyFetchResult` copies both into its own
///      `@MainActor` properties (`isRateLimited`, `rateLimitResetDate`).
///   5. `RunnerViewModel.reload()` mirrors them into `@Published` props.
///   6. `PanelMainView.rateLimitBanner` renders a live countdown using
///      `store.rateLimitResetDate` + the existing 1-second `displayTick`.
///
/// `@unchecked Sendable` because `DispatchWorkItem?` is not itself `Sendable`;
/// all mutation is serialised through `rateLimitLock`.
private struct RateLimitState: @unchecked Sendable {
    /// Whether the GitHub API is currently rate-limiting this client.
    var isLimited: Bool = false
    /// The moment at which the rate-limit window expires (mirrors X-RateLimit-Reset).
    /// `nil` when the reset time is unknown.
    var resetDate: Date?
    /// Pending work item that clears `isLimited` when it fires.
    var resetItem: DispatchWorkItem?
}

/// Lock that serialises all reads and writes to `RateLimitState`.
private let rateLimitLock = OSAllocatedUnfairLock(initialState: RateLimitState())

/// Thread-safe read/write access to the rate-limited flag.
var ghIsRateLimited: Bool {
    get { rateLimitLock.withLock { $0.isLimited } }
    set {
        rateLimitLock.withLock {
            $0.isLimited = newValue
            if !newValue { $0.resetDate = nil }
        }
        if newValue {
            scheduleRateLimitReset(resetAt: nil)
        }
    }
}

/// The exact `Date` at which the current rate-limit window expires.
///
/// `nil` when no rate-limit is active or when the reset time is unknown.
var ghRateLimitResetDate: Date? {
    rateLimitLock.withLock { $0.resetDate }
}

/// Schedules an automatic reset of `ghIsRateLimited` to `false`.
///
/// Uses a cancel-and-replace `DispatchWorkItem` so that multiple concurrent
/// 403/429 responses never leave more than one pending reset timer in flight.
///
/// - Parameter resetAt: Unix timestamp from the `X-RateLimit-Reset` response
///   header. When non-nil the reset fires precisely at that time; otherwise
///   falls back to 60 minutes from now.
private func scheduleRateLimitReset(resetAt: TimeInterval?) {
    let delay: TimeInterval
    let resetDate: Date
    if let ts = resetAt {
        let secondsUntilReset = ts - Date().timeIntervalSince1970
        delay = min(max(secondsUntilReset, 5), 7200)
        resetDate = Date(timeIntervalSince1970: ts)
    } else {
        delay = 3600
        resetDate = Date().addingTimeInterval(delay)
    }
    log("ghIsRateLimited › auto-reset scheduled in \(Int(delay))s (resetDate=\(resetDate))")

    let item = DispatchWorkItem {
        rateLimitLock.withLock {
            $0.isLimited = false
            $0.resetDate = nil
            $0.resetItem = nil
        }
        log("ghIsRateLimited › auto-reset fired after \(Int(delay))s")
    }
    rateLimitLock.withLock {
        $0.resetItem?.cancel()
        $0.resetItem = item
        $0.resetDate = resetDate
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
}

// MARK: - URLSession transport
//
// All GitHub API calls use URLSession + Authorization: Bearer header.
// All functions block the calling thread via DispatchSemaphore.
// ⚠️ Must always be called from a background thread.

// MARK: - Request builder

/// Builds a pre-configured URLRequest with standard GitHub API headers.
private func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Builds a URLRequest with `application/vnd.github.v3.raw` Accept header.
/// Used for log endpoints that 302-redirect to raw S3 content.
private func makeRawRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Resolves an endpoint string to a full GitHub API URL string.
private func resolveURL(_ endpoint: String) -> String {
    endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
}

/// Clears the rate-limit flag and cancels any pending reset timer.
/// Called after every successful (2xx) URLSession response.
private func clearRateLimitIfNeeded() {
    rateLimitLock.withLock {
        guard $0.isLimited else { return }
        $0.isLimited = false
        $0.resetDate = nil
        $0.resetItem?.cancel()
        $0.resetItem = nil
    }
}

/// Logs the response body (up to 400 chars) for non-2xx responses.
private func logErrorBody(_  Data?, endpoint: String, status: Int) {
    guard let data, !data.isEmpty else { return }
    let body = String( data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
    let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
    log("URLSessionTransport › \(endpoint) status=\(status) body: \(preview)")
}

/// Handles a 403/429 HTTP response, setting rate-limit state when appropriate.
private func handleRateLimitResponse(
    statusCode: Int,
    _  Data?,
    response: HTTPURLResponse,
    endpoint: String
) {
    let resetTS = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        .flatMap { TimeInterval($0) }
    let isRealRateLimit = statusCode == 429
        || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    if isRealRateLimit {
        logErrorBody(data, endpoint: endpoint, status: statusCode)
        log("URLSessionTransport › ⚠️ rate limited — \(endpoint) status=\(statusCode)")
        rateLimitLock.withLock { $0.isLimited = true }
        scheduleRateLimitReset(resetAt: resetTS)
    } else {
        log("URLSessionTransport › 403 permission error (not rate limit) — \(endpoint)")
    }
}

// MARK: - GET

/// Fetches a single GitHub API page synchronously (blocking the calling thread).
/// ⚠️ Must be called from a background thread, never from the main thread.
func urlSessionAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionAPI › no token available")
        return nil
    }
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
        log("urlSessionAPI › invalid URL: \(urlString)")
        return nil
    }
    let req = makeRequest(url: url, token: token, timeout: timeout)
    let sem = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<Data?>(initialState: nil)
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("URLSessionTransport › \(urlString) network error: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 403 || http.statusCode == 429 {
            handleRateLimitResponse(statusCode: http.statusCode, data, response: http, endpoint: urlString)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return
        }
        clearRateLimitIfNeeded()
        result.withLock { $0 = data }
    }.resume()
    sem.wait()
    return result.withLock { $0 }
}

/// Fetches all pages of a GitHub API endpoint, concatenating JSON arrays.
/// Follows the `Link: <url>; rel="next"` header automatically.
/// ⚠️ Must be called from a background thread, never from the main thread.
func urlSessionAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionAPIPaginated › no token available")
        return nil
    }
    var nextURL: String? = resolveURL(endpoint)
    var allItems: [[String: Any]] = []
    while let urlString = nextURL {
        guard let url = URL(string: urlString) else { break }
        let req = makeRequest(url: url, token: token, timeout: timeout)
        let sem = DispatchSemaphore(value: 0)
        let pageData = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let linkHeader = OSAllocatedUnfairLock<String?>(initialState: nil)
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                log("URLSessionTransport(paginated) › \(urlString) network error: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 403 || http.statusCode == 429 {
                handleRateLimitResponse(statusCode: http.statusCode, data, response: http, endpoint: urlString)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                logErrorBody(data, endpoint: urlString, status: http.statusCode)
                return
            }
            clearRateLimitIfNeeded()
            linkHeader.withLock { $0 = http.value(forHTTPHeaderField: "Link") }
            pageData.withLock { $0 = data }
        }.resume()
        sem.wait()
        guard let data = pageData.withLock({ $0 }) else { break }
        if let page = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            allItems.append(contentsOf: page)
        }
        nextURL = extractNextURL(from: linkHeader.withLock({ $0 }))
    }
    guard !allItems.isEmpty else { return nil }
    return try? JSONSerialization.data(withJSONObject: allItems)
}

/// Parses the `Link` header and returns the URL for `rel="next"`, if present.
private func extractNextURL(from header: String?) -> String? {
    guard let header else { return nil }
    for part in header.components(separatedBy: ",") {
        let segments = part.components(separatedBy: ";")
        guard segments.count >= 2 else { continue }
        let linkSegment = segments[0].trimmingCharacters(in: .whitespaces)
        guard linkSegment.hasPrefix("<"), linkSegment.hasSuffix(">") else { continue }
        let link = String(linkSegment.dropFirst().dropLast())
        let isNext = segments.dropFirst().contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
        })
        if isNext { return link }
    }
    return nil
}

// MARK: - Raw (log endpoints)

/// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3.
/// URLSession follows the redirect automatically.
/// ⚠️ Must be called from a background thread.
func urlSessionRaw(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionRaw › no token available")
        return nil
    }
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
        log("urlSessionRaw › invalid URL: \(urlString)")
        return nil
    }
    let req = makeRawRequest(url: url, token: token, timeout: timeout)
    let sem = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<Data?>(initialState: nil)
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("urlSessionRaw › \(urlString) network error: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return
        }
        result.withLock { $0 = data }
    }.resume()
    sem.wait()
    let data = result.withLock { $0 }
    log("urlSessionRaw › \(endpoint) → \(data?.count ?? 0)b")
    return data
}

// MARK: - POST / DELETE / PUT (mutation)

/// Sends a POST to the given GitHub API endpoint. Returns the response body, or nil on failure.
/// ⚠️ Must be called from a background thread.
@discardableResult
func urlSessionPost(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionPost › no token available")
        return nil
    }
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
        log("urlSessionPost › invalid URL: \(urlString)")
        return nil
    }
    var req = makeRequest(url: url, token: token, timeout: timeout)
    req.httpMethod = "POST"
    if let body {
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<Data?>(initialState: nil)
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("urlSessionPost › \(urlString) network error: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return
        }
        result.withLock { $0 = data ?? Data() }
        log("urlSessionPost › \(endpoint) → \(http.statusCode)")
    }.resume()
    sem.wait()
    return result.withLock { $0 }
}

/// Sends a PUT to the given GitHub API endpoint with a JSON body. Returns the response body, or nil on failure.
/// ⚠️ Must be called from a background thread.
func urlSessionPut(_ endpoint: String, body: Data, timeout: TimeInterval = 30) -> Data? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionPut › no token available")
        return nil
    }
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
        log("urlSessionPut › invalid URL: \(urlString)")
        return nil
    }
    var req = makeRequest(url: url, token: token, timeout: timeout)
    req.httpMethod = "PUT"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let sem = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock<Data?>(initialState: nil)
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("urlSessionPut › \(urlString) network error: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return
        }
        result.withLock { $0 = data }
        log("urlSessionPut › \(endpoint) → \(http.statusCode)")
    }.resume()
    sem.wait()
    return result.withLock { $0 }
}

/// Sends a DELETE to the given GitHub API endpoint. Returns true on success (2xx).
/// ⚠️ Must be called from a background thread.
@discardableResult
func urlSessionDelete(_ endpoint: String, timeout: TimeInterval = 30) -> Bool {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let token = githubToken() else {
        log("urlSessionDelete › no token available")
        return false
    }
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
        log("urlSessionDelete › invalid URL: \(urlString)")
        return false
    }
    var req = makeRequest(url: url, token: token, timeout: timeout)
    req.httpMethod = "DELETE"
    let sem = DispatchSemaphore(value: 0)
    let success = OSAllocatedUnfairLock<Bool>(initialState: false)
    URLSession.shared.dataTask(with: req) { data, response, error in
        defer { sem.signal() }
        if let error {
            log("urlSessionDelete › \(urlString) network error: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else { return }
        let ok = (200..<300).contains(http.statusCode)
        if !ok { logErrorBody(data, endpoint: urlString, status: http.statusCode) }
        success.withLock { $0 = ok }
        log("urlSessionDelete › \(endpoint) → \(http.statusCode)")
    }.resume()
    sem.wait()
    return success.withLock { $0 }
}

// MARK: - Public API entry points (GET)

/// Calls the GitHub REST API for a single page via URLSession.
/// Returns nil when no token is available or the request fails.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) -> Data? {
    guard githubToken() != nil else {
        log("ghAPI › no token available for: \(endpoint)")
        return nil
    }
    return urlSessionAPI(endpoint, timeout: timeout)
}

/// Calls the GitHub REST API for all pages via URLSession.
/// Returns nil when no token is available or the request fails.
func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    guard githubToken() != nil else {
        log("ghAPIPaginated › no token available for: \(endpoint)")
        return nil
    }
    return urlSessionAPIPaginated(endpoint, timeout: timeout)
}

// MARK: - Runner mutation helpers

/// Directly deregisters a runner from GitHub via DELETE.
/// Returns true on success (HTTP 204 No Content).
@discardableResult
func deleteRunnerByID(scope scopeString: String, runnerID: Int) -> Bool {
    guard let scope = Scope.parse(scopeString) else {
        log("deleteRunnerByID › invalid scope: \(scopeString)")
        return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)"
    log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)")
    let success = urlSessionDelete(endpoint)
    if !success { log("deleteRunnerByID › failed for runnerID=\(runnerID)") }
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
    guard let bodyData = try? JSONSerialization.data(withJSONObject: ["labels": labels]) else {
        log("patchRunnerLabels › failed to serialise request body")
        return nil
    }
    guard let outData = urlSessionPut(endpoint, body: bodyData) else {
        log("patchRunnerLabels › request failed for endpoint=\(endpoint)")
        return nil
    }
    struct LabelsResponse: Decodable {
        /// A single runner label.
        struct Label: Decodable { let name: String }
        /// The updated labels list.
        let labels: [Label]
    }
    guard let resp = try? JSONDecoder().decode(LabelsResponse.self, from: outData) else {
        let raw = String( outData, encoding: .utf8) ?? ""
        log("patchRunnerLabels › decode failed raw=\(raw.prefix(200))")
        return nil
    }
    let names = resp.labels.map(\.name)
    log("patchRunnerLabels › success labels=\(names)")
    return names
}

/// Fetches a short-lived runner registration token for the given scope.
func fetchRegistrationToken(scope scopeString: String) -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRegistrationToken › invalid scope: \(scopeString)")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/registration-token"
    log("fetchRegistrationToken › POSTing \(endpoint)")
    guard let outputData = urlSessionPost(endpoint) else {
        log("fetchRegistrationToken › no data for \(endpoint)")
        return nil
    }
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
    guard let outputData = urlSessionPost(endpoint) else {
        log("fetchRemovalToken › no data returned for \(endpoint)")
        return nil
    }
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("fetchRemovalToken › decode failed for \(endpoint) (\(outputData.count)b)")
        return nil
    }
    log("fetchRemovalToken › got removal token")
    return resp.token
}

/// Sends a POST to the given GitHub API endpoint. Returns true on success (2xx).
/// ⚠️ Must be called from a background thread.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    let result = urlSessionPost(endpoint)
    let success = result != nil
    log("ghPost › \(endpoint) success=\(success)")
    return success
}

/// Cancels a workflow run.
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
