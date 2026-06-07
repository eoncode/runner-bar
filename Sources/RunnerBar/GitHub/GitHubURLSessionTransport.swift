// GitHubURLSessionTransport.swift
// RunnerBar

// @preconcurrency suppresses Sendable warnings from pre-Swift-6 Foundation types
// (URLRequest, URLResponse, Data) used in completion handler closures.
@preconcurrency import Foundation
import os

// MARK: - Rate limit flag

/// Combined rate-limit state held under a single lock.
///
/// Both `isLimited` and `resetDate` are mutated together so that a reader
/// can never observe `isLimited == true` with a stale / nil `resetDate`.
///
/// Pipeline:
///   1. `urlSessionAPIAsync` / `urlSessionAPIPaginated` receive a 403/429.
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
///
/// The setter coordinates `isLimited` and `resetDate` within the same critical
/// section via `scheduleRateLimitReset`, so readers never observe
/// `isLimited == true` with `resetDate == nil`.
var ghIsRateLimited: Bool {
    get { rateLimitLock.withLock { $0.isLimited } }
    set {
        if newValue {
            // No X-RateLimit-Reset header available at this call site;
            // scheduleRateLimitReset falls back to a 60-minute window.
            scheduleRateLimitReset(resetAt: nil)
        } else {
            rateLimitLock.withLock {
                $0.isLimited = false
                $0.resetDate = nil
                // cancel() is thread-safe and non-blocking; safe to call under the lock.
                $0.resetItem?.cancel()
                $0.resetItem = nil
            }
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
/// Sets `isLimited = true` and `resetDate` together inside the lock before
/// scheduling the work item, so the `isLimited == true` / `resetDate != nil`
/// invariant is always satisfied when `handleRateLimitResponse` calls this.
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
        $0.isLimited = true
        $0.resetItem?.cancel()
        $0.resetItem = item
        $0.resetDate = resetDate
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
}

// MARK: - URLSession transport
//
// All GitHub API calls use URLSession + Authorization: Bearer header.
// The mutation helpers in this file (`urlSessionPost`, `urlSessionPut`,
// `urlSessionDelete`, `urlSessionRaw`) are intentionally synchronous legacy
// wrappers built on `URLSession.dataTask + DispatchSemaphore.wait()`.
//
// Safety contract:
// - Never call them from `@MainActor` / the main queue.
// - Never call them from an `async` function that is expected to suspend rather
//   than block a cooperative pool thread.
// - Safe call sites are synchronous background threads or non-main-actor pool tasks
//   that explicitly accept a brief blocking section.

// MARK: - Request builder

/// Module-level constant reused by `resolveURL` to avoid allocating a new
/// `CharacterSet` on every API call and pagination iteration.
private let slashCharacterSet = CharacterSet(charactersIn: "/")

/// Builds a URLRequest with the standard GitHub API headers shared by all
/// request types: `Authorization`, `X-GitHub-Api-Version`.
/// Callers set the `Accept` header for their specific media type.
private func makeBaseRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Builds a pre-configured URLRequest with standard GitHub API headers.
private func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
}

/// Builds a URLRequest with `application/vnd.github.v3.raw` Accept header.
/// Used for log endpoints that 302-redirect to raw S3 content.
///
/// # S3 redirect safety
/// The `Authorization: Bearer` header set here is sent only to api.github.com.
/// When GitHub replies with 302 to a pre-signed S3 URL (*.amazonaws.com),
/// Apple's URLSession automatically strips sensitive headers — including
/// `Authorization` — before following the redirect to a different domain
/// (cross-origin redirect semantics per RFC 7235 / Apple URLSession behaviour).
/// S3 therefore receives only the pre-signed query-param credentials and no
/// conflicting `Authorization` header. No custom redirect delegate is required.
private func makeRawRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
    return req
}

/// Resolves an endpoint string to a full GitHub API URL string.
private func resolveURL(_ endpoint: String) -> String {
    endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: slashCharacterSet))"
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
private func logErrorBody(_ data: Data?, endpoint: String, status: Int) {
    guard let data, !data.isEmpty else { return }
    let body = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
    let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
    log("URLSessionTransport › \(endpoint) status=\(status) body: \(preview)")
}

/// Handles a 403/429 HTTP response, setting rate-limit state when appropriate.
///
/// Sets `isLimited = true` and `resetDate` atomically inside `scheduleRateLimitReset`
/// so that `isLimited == true` with `resetDate == nil` is never observable.
///
/// **Primary rate limits** (`429`, or `403` with `X-RateLimit-Remaining == 0`):
/// detected via status code or the remaining-quota header.
///
/// **Secondary rate limits** (`403` with a `Retry-After` header and non-zero remaining):
/// GitHub uses this for per-minute abuse / concurrency throttling. The `Retry-After`
/// value (seconds) is used as the reset delay so the timer honours the server window.
/// See https://docs.github.com/en/rest/overview/rate-limits-for-the-rest-api#secondary-rate-limits
private func handleRateLimitResponse(
    statusCode: Int,
    _ data: Data?,
    response: HTTPURLResponse,
    endpoint: String
) {
    let resetTS = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        .flatMap { TimeInterval($0) }
    let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    let isRealRateLimit = statusCode == 429 || remaining == 0 || retryAfter != nil
    if isRealRateLimit {
        logErrorBody(data, endpoint: endpoint, status: statusCode)
        let limitKind = retryAfter != nil && remaining != 0 ? "secondary" : "primary"
        log("URLSessionTransport › ⚠️ rate limited (\(limitKind)) — \(endpoint) status=\(statusCode)")
        let effectiveResetTS: TimeInterval?
        if let retryAfter, resetTS == nil {
            effectiveResetTS = Date().timeIntervalSince1970 + retryAfter
        } else {
            effectiveResetTS = resetTS
        }
        scheduleRateLimitReset(resetAt: effectiveResetTS)
    } else {
        log("URLSessionTransport › 403 permission error (not rate limit) — \(endpoint)")
    }
}

// MARK: - Async GET (primary transport)

/// Fetches a single GitHub API page using `URLSession.data(for:)` async/await.
///
/// This is the primary transport for all `ghAPI` calls. It is non-blocking and
/// natively cancellable via `Task.cancel()`.
///
/// - S3 redirect safety: GitHub artifact/log endpoints can redirect to S3.
///   `URLSession` follows redirects automatically; the `Authorization` header
///   is stripped before replaying to a different domain (cross-origin redirect
///   semantics per RFC 7235 / Apple URLSession behaviour), so the Bearer token
///   is never forwarded to S3. No custom redirect delegate is required.
/// - Rate limiting: a 403 with `X-RateLimit-Remaining: 0` or a 429 sets
///   `ghIsRateLimited` via `handleRateLimitResponse`. A successful response
///   clears it via `clearRateLimitIfNeeded()`. The flag is also reset at the
///   start of each poll cycle in `RunnerStore.fetch()`.
func urlSessionAPIAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    guard let token = githubToken() else {
        log("urlSessionAPIAsync › no token available")
        return nil
    }
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
        log("urlSessionAPIAsync › invalid URL: \(urlString)")
        return nil
    }
    let req = makeRequest(url: url, token: token, timeout: timeout)
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 403 || http.statusCode == 429 {
            handleRateLimitResponse(statusCode: http.statusCode, data, response: http, endpoint: urlString)
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return nil
        }
        clearRateLimitIfNeeded()
        return data
    } catch {
        log("urlSessionAPIAsync › \(urlString) network error: \(error.localizedDescription)")
        return nil
    }
}

/// Fetches and concatenates all pages for a GitHub paginated endpoint using
/// `URLSession.data(for:)` async/await.
///
/// Follows the `Link: <url>; rel="next"` header automatically until all pages
/// are consumed or an error stops pagination.
///
/// - Token is re-fetched on every loop iteration so that a sign-out mid-pagination
///   is detected immediately rather than continuing with a stale credential.
/// - A `401 Unauthorized` response breaks the loop, discards any partial results,
///   and returns `nil` so callers can distinguish auth failure from a complete dataset.
/// - A non-array page response (unexpected shape) also breaks the loop with a log.
func urlSessionAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    var nextURL: String? = resolveURL(endpoint)
    var allItems: [[String: Any]] = []
    var didFailAuthentication = false

    while let urlString = nextURL {
        guard let token = githubToken() else {
            log("urlSessionAPIPaginated › no token available, stopping pagination")
            didFailAuthentication = true
            break
        }
        guard let url = URL(string: urlString) else { break }

        let req = makeRequest(url: url, token: token, timeout: timeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { break }

            if http.statusCode == 401 {
                log("urlSessionAPIPaginated › 401 Unauthorized — token may have been revoked, stopping pagination")
                didFailAuthentication = true
                break
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                handleRateLimitResponse(statusCode: http.statusCode, data, response: http, endpoint: urlString)
                break
            }
            guard (200..<300).contains(http.statusCode) else {
                logErrorBody(data, endpoint: urlString, status: http.statusCode)
                break
            }

            clearRateLimitIfNeeded()
            if let page = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                allItems.append(contentsOf: page)
            } else {
                log("urlSessionAPIPaginated › unexpected non-array response at \(urlString) — stopping pagination")
                break
            }
            nextURL = extractNextURL(from: http.value(forHTTPHeaderField: "Link"))
        } catch {
            log("URLSessionTransport(paginated) › \(urlString) network error: \(error.localizedDescription)")
            break
        }
    }

    if didFailAuthentication {
        if !allItems.isEmpty {
            log("urlSessionAPIPaginated › authentication failed mid-pagination — discarding \(allItems.count) partial items")
        }
        return nil
    }
    if ghIsRateLimited && !allItems.isEmpty {
        log("urlSessionAPIPaginated › pagination stopped by rate limit — returning \(allItems.count) partial items")
    }
    guard !allItems.isEmpty else { return nil }
    return try? JSONSerialization.data(withJSONObject: allItems)
}

/// Parses the `Link` header from a GitHub paginated response and returns the `next` URL, if any.
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
///
/// # Redirect safety
/// GitHub's job-log endpoint (`/actions/jobs/{id}/logs`) returns 302 to a
/// pre-signed S3 URL on `*.amazonaws.com`. URLSession follows this redirect
/// automatically. Apple's URLSession strips the `Authorization` header before
/// replaying a request to a different domain (cross-origin redirect — RFC 7235
/// / Apple URLSession cross-origin redirect semantics), so the Bearer token is
/// never forwarded to S3. S3 authenticates purely via the pre-signed query
/// params already embedded in the redirect URL. No custom redirect delegate is
/// required or appropriate here.
///
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
    let data = result.withLock { $0 }
    log("urlSessionRaw › \(endpoint) → \(data?.count ?? 0)b")
    return data
}

// MARK: - POST / DELETE / PUT (mutation)

/// Sends a POST to the given GitHub API endpoint. Returns the response body, or nil on failure.
///
/// Return value semantics:
/// - `nil`      — network failure or non-2xx status (request failed).
/// - `Data()`   — 2xx response with no body (e.g. 204 No Content); treat as success.
/// - `Data(…)`  — 2xx response with a body; decode as needed.
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
        if http.statusCode == 403 || http.statusCode == 429 {
            handleRateLimitResponse(statusCode: http.statusCode, data, response: http, endpoint: urlString)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return
        }
        clearRateLimitIfNeeded()
        result.withLock { $0 = data ?? Data() }
        log("urlSessionPost › \(endpoint) → \(http.statusCode)")
    }.resume()
    sem.wait()
    return result.withLock { $0 }
}

/// Sends a PUT to the given GitHub API endpoint with a JSON body. Returns the response body, or nil on failure.
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
        log("urlSessionPut › \(endpoint) → \(http.statusCode)")
    }.resume()
    sem.wait()
    return result.withLock { $0 }
}

/// Sends a DELETE to the given GitHub API endpoint. Returns true on success (2xx).
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
        if http.statusCode == 403 || http.statusCode == 429 {
            handleRateLimitResponse(statusCode: http.statusCode, data, response: http, endpoint: urlString)
            return
        }
        let ok = (200..<300).contains(http.statusCode)
        if !ok { logErrorBody(data, endpoint: urlString, status: http.statusCode) }
        if ok { clearRateLimitIfNeeded() }
        success.withLock { $0 = ok }
        log("urlSessionDelete › \(endpoint) → \(http.statusCode)")
    }.resume()
    sem.wait()
    return success.withLock { $0 }
}

// MARK: - Public API entry points (GET)

/// Calls the GitHub REST API for a single page via URLSession.
/// Returns nil when no token is available or the request fails.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await urlSessionAPIAsync(endpoint, timeout: timeout)
}

/// Calls the GitHub REST API for all pages via URLSession.
/// Returns nil when no token is available or the request fails.
func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    await urlSessionAPIPaginated(endpoint, timeout: timeout)
}

// MARK: - Runner mutation helpers

/// Directly deregisters a runner from GitHub via DELETE.
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
        struct Label: Decodable { let name: String }
        let labels: [Label]
    }
    guard let resp = try? JSONDecoder().decode(LabelsResponse.self, from: outData) else {
        let raw = String(data: outData, encoding: .utf8) ?? ""
        log("patchRunnerLabels › decode failed raw=\(raw.prefix(200))")
        return nil
    }
    let names = resp.labels.map(\.name)
    log("patchRunnerLabels › success labels=\(names)")
    return names
}

// MARK: - Runner token helpers

    /// Requests a runner token of the given `type` (e.g. registration or removal) for `scope`.
private func fetchRunnerToken(type: String, scope: Scope, logPrefix: String) -> String? {
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(type)"
    log("\(logPrefix) › POSTing \(endpoint)")
    guard let outputData = urlSessionPost(endpoint), !outputData.isEmpty else {
        log("\(logPrefix) › no data for \(endpoint)")
        return nil
    }
    struct TokenResponse: Decodable { let token: String }
    guard let resp = try? JSONDecoder().decode(TokenResponse.self, from: outputData) else {
        log("\(logPrefix) › decode failed (\(outputData.count)b)")
        return nil
    }
    return resp.token
}

/// Fetches a short-lived runner registration token for the given scope.
func fetchRegistrationToken(scope scopeString: String) -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRegistrationToken › invalid scope: \(scopeString)")
        return nil
    }
    guard let token = fetchRunnerToken(type: "registration-token", scope: scope, logPrefix: "fetchRegistrationToken") else { return nil }
    log("fetchRegistrationToken › got registration token")
    return token
}

/// Fetches a runner removal token for the given scope.
func fetchRemovalToken(scope scopeString: String) -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRemovalToken › invalid scope: \(scopeString)")
        return nil
    }
    guard let token = fetchRunnerToken(type: "remove-token", scope: scope, logPrefix: "fetchRemovalToken") else { return nil }
    log("fetchRemovalToken › got removal token")
    return token
}

/// Thin convenience wrapper over `urlSessionPost` for fire-and-forget mutation endpoints.
@discardableResult
func ghPost(_ endpoint: String) -> Bool {
    let result = urlSessionPost(endpoint)
    let success = result != nil
    log("ghPost › \(endpoint) success=\(success)")
    return success
}

/// Cancels a workflow run via the GitHub Actions API.
@discardableResult
func cancelRun(runID: Int, scope: String) -> Bool {
    let result = ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
