// GitHubURLSessionTransport.swift
// RunnerBar

import Foundation
import os

// MARK: - RateLimitActor

/// Actor-isolated rate-limit state.
///
/// Replaces the old `RateLimitState` struct + `OSAllocatedUnfairLock` + `DispatchWorkItem`
/// pattern. The actor serialises all reads and writes; the reset timer uses a structured
/// `Task` + `Task.sleep(for:)` instead of `DispatchQueue.global().asyncAfter`, so it is
/// natively cancellable and requires no `@unchecked Sendable` escape hatch.
///
/// Pipeline:
///   1. `urlSessionAPIAsync` / `urlSessionAPIPaginated` receive a 403/429.
///   2. They call `rateLimitActor.set(resetAt:)` to arm the rate-limit flag and
///      schedule an automatic clear after the window.
///   3. `ghIsRateLimited` / `ghRateLimitResetDate` expose the current values
///      as `async` computed properties backed by the actor.
///   4. `RunnerStore.applyFetchResult` copies both into its own `@MainActor`
///      properties (`isRateLimited`, `rateLimitResetDate`) via a single atomic
///      `snapshot()` call, eliminating the race window between two separate awaits.
///   5. `RunnerViewModel.reload()` mirrors them into `@Published` props.
///   6. `PanelMainView.rateLimitBanner` renders a live countdown using
///      `store.rateLimitResetDate` + the existing 1-second `displayTick`.
private actor RateLimitActor {
    /// Whether the GitHub API is currently rate-limiting this client.
    private(set) var isLimited = false
    /// The moment at which the rate-limit window expires (mirrors X-RateLimit-Reset).
    /// `nil` when the reset time is unknown.
    private(set) var resetDate: Date?
    /// Structured task that clears `isLimited` when it fires.
    private var resetTask: Task<Void, Never>?

    /// Arms the rate-limit flag and schedules an automatic reset.
    ///
    /// - Parameter resetAt: Unix timestamp from the `X-RateLimit-Reset` response header.
    ///   When non-nil the reset fires precisely at that time; otherwise falls back to
    ///   60 minutes from now.
    func set(resetAt: TimeInterval?) {
        let delay: TimeInterval
        let date: Date
        if let ts = resetAt {
            let secondsUntilReset = ts - Date().timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
            date = Date(timeIntervalSince1970: ts)
        } else {
            delay = 3600
            date = Date().addingTimeInterval(delay)
        }
        log("ghIsRateLimited › auto-reset scheduled in \(Int(delay))s (resetDate=\(date))")
        // Cancel any existing timer before arming a new one so that multiple
        // concurrent 403/429 responses never leave more than one pending reset in flight.
        resetTask?.cancel()
        isLimited = true
        resetDate = date
        resetTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // CancellationError — a newer set(resetAt:) or clear() raced in.
                return
            }
            await self.didFire(scheduledDelay: delay)
        }
    }

    /// Clears the rate-limit flag and cancels any pending reset task.
    /// Unconditional — no early-return guard — so `resetDate` is always
    /// cleared even if `isLimited` is somehow false, keeping the two
    /// properties in a consistent state regardless of call order.
    func clear() {
        resetTask?.cancel()
        resetTask = nil
        isLimited = false
        resetDate = nil
    }

    /// Returns both `isLimited` and `resetDate` in a single actor hop.
    ///
    /// Use this instead of two separate `await` calls on `ghIsRateLimited` and
    /// `ghRateLimitResetDate` to guarantee that the two values are consistent
    /// with each other — a `clear()` or `set(resetAt:)` call arriving between
    /// two separate awaits cannot produce a state where `isLimited == false`
    /// but `resetDate != nil`, or vice-versa.
    func snapshot() -> (isLimited: Bool, resetDate: Date?) {
        (isLimited: isLimited, resetDate: resetDate)
    }

    // MARK: Private

    /// Fires when the `Task.sleep` in `set(resetAt:)` completes without cancellation.
    /// Clears all rate-limit state so subsequent API calls are allowed through.
    private func didFire(scheduledDelay: TimeInterval) {
        isLimited = false
        resetDate = nil
        resetTask = nil
        log("ghIsRateLimited › auto-reset fired after \(Int(scheduledDelay))s")
    }
}

/// The module-wide rate-limit actor instance.
private let rateLimitActor = RateLimitActor()

// MARK: - Rate-limit accessors

/// Whether the GitHub API is currently rate-limiting this client.
///
/// Backed by `RateLimitActor`; must be `await`-ed from async contexts.
var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

/// Clears the rate-limit flag. Called at the start of each poll cycle in `RunnerStore.fetch()`.
func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

/// Returns `isLimited` and `resetDate` in a single actor hop.
///
/// Prefer this over separate `await ghIsRateLimited` + `await ghRateLimitResetDate` calls
/// to avoid the TOCTOU window between two hops.
func ghRateLimitSnapshot() async -> (isLimited: Bool, resetDate: Date?) {
    await rateLimitActor.snapshot()
}

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

/// Logs the response body (up to 400 chars) for non-2xx responses.
private func logErrorBody(_ data: Data?, endpoint: String, status: Int) {
    guard let data, !data.isEmpty else { return }
    let body = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count)b>"
    let preview = body.count > 400 ? String(body.prefix(400)) + "…" : body
    log("URLSessionTransport › \(endpoint) status=\(status) body: \(preview)")
}

/// Handles a 403/429 HTTP response, setting rate-limit state when appropriate.
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
) async {
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
        await rateLimitActor.set(resetAt: effectiveResetTS)
    } else {
        log("URLSessionTransport › 403 permission error (not rate limit) — \(endpoint)")
    }
}

// MARK: - Shared execution core

/// The result of a single URLSession round-trip through `urlSessionExecute`.
private enum ExecuteResult {
    /// 2xx response with optional body data (empty `Data()` for 204 No Content).
    case success(Data, statusCode: Int)
    /// Non-2xx response that is not a rate-limit; the request failed.
    case httpError(Int)
    /// 403 or 429 that triggered the rate-limit actor.
    case rateLimited
    /// Network-level error (timeout, no connectivity, etc.).
    case networkError(Error)
}

/// Single shared implementation of the token-guard → URL-resolve → send → handle-response
/// pipeline used by all public transport functions.
///
/// - Parameters:
///   - endpoint: GitHub REST API endpoint (absolute URL or relative path).
///   - timeout: URLSession timeout for the request.
///   - configure: Closure that receives a base `URLRequest` and returns the
///     fully-configured request to send (sets method, body, extra headers, etc.).
///     Receives a `makeRequest`-style request by default; pass `useRawAccept: true`
///     via the outer helper when a `v3.raw` Accept header is needed instead.
///   - logTag: Short identifier used in log messages (e.g. `"urlSessionPost"`).
///   - useRawAccept: When `true` the base request is built with
///     `makeRawRequest` instead of `makeRequest`.
private func urlSessionExecute(
    _ endpoint: String,
    timeout: TimeInterval,
    logTag: String,
    useRawAccept: Bool = false,
    configure: (URLRequest) -> URLRequest = { $0 }
) async -> ExecuteResult {
    guard let token = githubToken() else {
        log("\(logTag) › no token available")
        return .networkError(URLError(.userAuthenticationRequired))
    }
    let urlString = resolveURL(endpoint)
    guard let url = URL(string: urlString) else {
        log("\(logTag) › invalid URL: \(urlString)")
        return .networkError(URLError(.badURL))
    }
    let baseReq = useRawAccept
        ? makeRawRequest(url: url, token: token, timeout: timeout)
        : makeRequest(url: url, token: token, timeout: timeout)
    let req = configure(baseReq)
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            return .networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            await handleRateLimitResponse(
                statusCode: http.statusCode, data, response: http, endpoint: urlString
            )
            return .rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return .httpError(http.statusCode)
        }
        await rateLimitActor.clear()
        return .success(data, statusCode: http.statusCode)
    } catch {
        log("\(logTag) › \(urlString) network error: \(error.localizedDescription)")
        return .networkError(error)
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
///   clears it via `rateLimitActor.clear()`. The flag is also reset at the
///   start of each poll cycle in `RunnerStore.fetch()`.
func urlSessionAPIAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    guard case .success(let data, _) = await urlSessionExecute(
        endpoint, timeout: timeout, logTag: "urlSessionAPIAsync"
    ) else { return nil }
    return data
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
                await handleRateLimitResponse(statusCode: http.statusCode, data, response: http, endpoint: urlString)
                break
            }
            guard (200..<300).contains(http.statusCode) else {
                logErrorBody(data, endpoint: urlString, status: http.statusCode)
                break
            }

            await rateLimitActor.clear()
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
    let isRateLimited = await ghIsRateLimited
    if isRateLimited && !allItems.isEmpty {
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

// MARK: - Raw async (log endpoints)

/// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3, using async/await.
///
/// This is the primary transport for all `ghRaw` calls, replacing the
/// DispatchSemaphore-based `urlSessionRaw`. It is non-blocking and natively
/// cancellable via `Task.cancel()`.
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
func urlSessionRaw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    guard case .success(let data, _) = await urlSessionExecute(
        endpoint, timeout: timeout, logTag: "urlSessionRaw", useRawAccept: true
    ) else { return nil }
    log("urlSessionRaw › \(endpoint) → \(data.count)b")
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
func urlSessionPost(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    let result = await urlSessionExecute(endpoint, timeout: timeout, logTag: "urlSessionPost") { req in
        var r = req
        r.httpMethod = "POST"
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }
    guard case .success(let data, let statusCode) = result else { return nil }
    log("urlSessionPost › \(endpoint) → \(statusCode)")
    return data
}

/// Sends a PUT to the given GitHub API endpoint with a JSON body. Returns the response body, or nil on failure.
func urlSessionPut(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    let result = await urlSessionExecute(endpoint, timeout: timeout, logTag: "urlSessionPut") { req in
        var r = req
        r.httpMethod = "PUT"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }
    guard case .success(let data, let statusCode) = result else { return nil }
    log("urlSessionPut › \(endpoint) → \(statusCode)")
    return data
}

/// Sends a DELETE to the given GitHub API endpoint. Returns true on success (2xx).
@discardableResult
func urlSessionDelete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    let result = await urlSessionExecute(endpoint, timeout: timeout, logTag: "urlSessionDelete") { req in
        var r = req
        r.httpMethod = "DELETE"
        return r
    }
    if case .success = result {
        log("urlSessionDelete › \(endpoint) → success")
        return true
    }
    return false
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
func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    guard let scope = Scope.parse(scopeString) else {
        log("deleteRunnerByID › invalid scope: \(scopeString)")
        return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)"
    log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)")
    let success = await urlSessionDelete(endpoint)
    if !success { log("deleteRunnerByID › failed for runnerID=\(runnerID)") }
    return success
}

/// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
@discardableResult
func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
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
    guard let outData = await urlSessionPut(endpoint, body: bodyData) else {
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
private func fetchRunnerToken(type: String, scope: Scope, logPrefix: String) async -> String? {
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(type)"
    log("\(logPrefix) › POSTing \(endpoint)")
    // GitHub token endpoints always return a JSON body; a nil result means a network/auth
    // failure (urlSessionPost already logged it). Empty data would indicate an unexpected
    // 204 No Content, which token endpoints do not emit — treat as failure either way.
    guard let outputData = await urlSessionPost(endpoint) else {
        log("\(logPrefix) › request failed for \(endpoint)")
        return nil
    }
    guard !outputData.isEmpty else {
        log("\(logPrefix) › unexpected empty body for \(endpoint) (204?)")
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
func fetchRegistrationToken(scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRegistrationToken › invalid scope: \(scopeString)")
        return nil
    }
    guard let token = await fetchRunnerToken(type: "registration-token", scope: scope, logPrefix: "fetchRegistrationToken") else { return nil }
    log("fetchRegistrationToken › got registration token")
    return token
}

/// Fetches a runner removal token for the given scope.
func fetchRemovalToken(scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRemovalToken › invalid scope: \(scopeString)")
        return nil
    }
    guard let token = await fetchRunnerToken(type: "remove-token", scope: scope, logPrefix: "fetchRemovalToken") else { return nil }
    log("fetchRemovalToken › got removal token")
    return token
}

/// Thin convenience wrapper over `urlSessionPost` for fire-and-forget mutation endpoints.
@discardableResult
func ghPost(_ endpoint: String) async -> Bool {
    let result = await urlSessionPost(endpoint)
    let success = result != nil
    log("ghPost › \(endpoint) success=\(success)")
    return success
}

/// Cancels a workflow run via the GitHub Actions API.
@discardableResult
func cancelRun(runID: Int, scope: String) async -> Bool {
    let result = await ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
