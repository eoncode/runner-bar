// GitHubURLSessionTransport.swift
// RunnerBar

import Foundation
import RunnerBarCore

/// Shared decoder hoisted to avoid re-instantiation on every call.
/// Thread-safe: `JSONDecoder` has no mutable state after initialisation.
private let sharedDecoder = JSONDecoder()
/// Shared encoder hoisted to avoid re-instantiation on every call.
/// Thread-safe: `JSONEncoder` has no mutable state after initialisation.
private let sharedEncoder = JSONEncoder()

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
///   - endpoint: A relative path (e.g. `repos/owner/repo/actions/runners`) or an absolute
///     URL string. Relative paths are resolved against `GitHubConstants.apiBase`.
///   - timeout: The `URLRequest.timeoutInterval` for this request. Callers should pass a
///     value appropriate for the operation: short for single-page GETs, longer for raw log
///     downloads or mutations.
///   - logTag: A short prefix prepended to all `log()` calls within the function, so log
///     output can be correlated back to the specific call site (e.g. `"urlSessionPost"`).
///   - useRawAccept: When `true`, sets `Accept: application/vnd.github.v3.raw` instead of
///     the standard JSON header. Required for log endpoints that 302-redirect to raw S3
///     content.
///   - configure: A closure applied to the pre-built `URLRequest` just before it is sent.
///     Use this to set `httpMethod`, `httpBody`, or additional headers. The closure receives
///     the base request and must return the mutated copy; the default is the identity closure.
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
/// Intentionally internal: this is a stable call site consumed by `RunnerStore` and other
/// module-level consumers across files. The underlying `urlSessionExecute` remains private
/// to this file.
func urlSessionAPIAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    guard case .success(let data, _) = await urlSessionExecute(
        endpoint, timeout: timeout, logTag: "urlSessionAPIAsync"
    ) else { return nil }
    return data
}

/// Fetches and concatenates all pages for a GitHub paginated endpoint.
/// Follows `Link: <url>; rel="next"` until all pages are consumed or an error stops pagination.
/// Returns `nil` on auth failure; returns partial results if pagination is stopped by a rate limit.
func urlSessionAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    var nextURL: String? = resolveURL(endpoint)
    var allItems: [AnyJSON] = []
    var didFailAuthentication = false
    let decoder = sharedDecoder
    let encoder = sharedEncoder

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
            if let page = try? decoder.decode([AnyJSON].self, from: data) {
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
    return try? encoder.encode(allItems)
}

// MARK: - Raw async (log endpoints)

/// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3.
///
/// - Note: This function uses `makeRawRequest` which sets `Accept: application/vnd.github.v3.raw`.
///   Apple’s URLSession strips the `Authorization` header before following cross-origin
///   redirects (RFC 7235), so the Bearer token is never forwarded to S3.
///   See `makeRawRequest` in `GitHubRequestBuilder.swift` for full details.
func urlSessionRaw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    guard case .success(let data, _) = await urlSessionExecute(
        endpoint, timeout: timeout, logTag: "urlSessionRaw", useRawAccept: true
    ) else { return nil }
    log("urlSessionRaw › \(endpoint) → \(data.count)b")
    return data
}

// MARK: - POST / DELETE / PUT (mutation)

/// Sends a POST to the given GitHub API endpoint.
///
/// Intentionally internal: backs `ghPost` and the runner mutation helpers below,
/// all of which are called from outside this file.
/// - Returns: Response body on 2xx (`Data()` for 204 No Content), `nil` on failure.
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

/// Sends a PUT to the given GitHub API endpoint with a JSON body.
/// - Returns: Response body on 2xx, `nil` on failure.
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

/// Sends a DELETE to the given GitHub API endpoint.
/// - Returns: `true` on 2xx, `false` on any failure.
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
/// Returns `nil` when no token is available or the request fails.
func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await urlSessionAPIAsync(endpoint, timeout: timeout)
}

/// Calls the GitHub REST API for all pages via URLSession.
/// Returns `nil` when no token is available or the request fails.
func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    await urlSessionAPIPaginated(endpoint, timeout: timeout)
}

// MARK: - Runner mutation helpers

/// Directly deregisters a runner from GitHub via DELETE.
/// - Returns: `true` on success, `false` if the scope is invalid or the request fails.
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

/// Encodable body for the GitHub runner labels PUT endpoint.
private struct LabelsBody: Encodable {
    /// The label names to set on the runner.
    let labels: [String] // periphery:ignore
}

/// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
/// - Returns: The updated label names on success, `nil` on any failure.
@discardableResult
func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    guard let scope = Scope.parse(scopeString) else {
        log("patchRunnerLabels › invalid scope: \(scopeString)")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
    log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)")
    guard let bodyData = try? sharedEncoder.encode(LabelsBody(labels: labels)) else {
        log("patchRunnerLabels › failed to serialise request body")
        return nil
    }
    guard let outData = await urlSessionPut(endpoint, body: bodyData) else {
        log("patchRunnerLabels › request failed for endpoint=\(endpoint)")
        return nil
    }
    /// Decodable shape returned by the GitHub runner labels PUT endpoint.
    struct LabelsResponse: Decodable {
        /// A single label entry returned by the labels endpoint.
        struct Label: Decodable {
            /// The label name string.
            let name: String
        }
        /// The full list of labels now assigned to the runner.
        let labels: [Label]
    }
    guard let resp = try? sharedDecoder.decode(LabelsResponse.self, from: outData) else {
        let raw = String(data: outData, encoding: .utf8) ?? ""
        log("patchRunnerLabels › decode failed raw=\(raw.prefix(200))")
        return nil
    }
    let names = resp.labels.map(\.name)
    log("patchRunnerLabels › success labels=\(names)")
    return names
}

// MARK: - Runner token helpers

/// Requests a runner token of the given `type` (registration or removal) for `scope`.
/// Shared implementation used by `fetchRegistrationToken` and `fetchRemovalToken`.
///
/// GitHub token endpoints always return a JSON body; a `nil` result here means a
/// network or auth failure upstream. An empty-body response would indicate an unexpected
/// 204 No Content — token endpoints do not emit 204, so that branch guards against
/// future API changes or misconfigured proxies stripping the body.
private func fetchRunnerToken(type: String, scope: Scope, logPrefix: String) async -> String? {
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(type)"
    log("\(logPrefix) › POSTing \(endpoint)")
    guard let outputData = await urlSessionPost(endpoint) else {
        log("\(logPrefix) › request failed for \(endpoint)")
        return nil
    }
    guard !outputData.isEmpty else {
        log("\(logPrefix) › unexpected empty body for \(endpoint) (204?)")
        return nil
    }
    /// Decodable shape for GitHub runner token endpoints.
    struct TokenResponse: Decodable {
        /// The short-lived token string returned by GitHub.
        let token: String
    }
    guard let resp = try? sharedDecoder.decode(TokenResponse.self, from: outputData) else {
        log("\(logPrefix) › decode failed (\(outputData.count)b)")
        return nil
    }
    return resp.token
}

/// Fetches a short-lived runner registration token for the given scope.
/// - Returns: The registration token string, or `nil` on failure.
func fetchRegistrationToken(scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRegistrationToken › invalid scope: \(scopeString)")
        return nil
    }
    guard let token = await fetchRunnerToken(
        type: "registration-token", scope: scope, logPrefix: "fetchRegistrationToken"
    ) else { return nil }
    log("fetchRegistrationToken › got registration token")
    return token
}

/// Fetches a runner removal token for the given scope.
/// - Returns: The removal token string, or `nil` on failure.
func fetchRemovalToken(scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchRemovalToken › invalid scope: \(scopeString)")
        return nil
    }
    guard let token = await fetchRunnerToken(
        type: "remove-token", scope: scope, logPrefix: "fetchRemovalToken"
    ) else { return nil }
    log("fetchRemovalToken › got removal token")
    return token
}

// MARK: - Convenience wrappers

/// Thin convenience wrapper over `urlSessionPost` for fire-and-forget mutation endpoints.
/// - Returns: `true` if the POST returned a non-nil result (2xx), `false` otherwise.
@discardableResult
func ghPost(_ endpoint: String) async -> Bool {
    let result = await urlSessionPost(endpoint)
    let success = result != nil
    log("ghPost › \(endpoint) success=\(success)")
    return success
}

/// Cancels a workflow run via the GitHub Actions API.
/// - Returns: `true` if the cancellation request succeeded.
@discardableResult
func cancelRun(runID: Int, scope: String) async -> Bool {
    let result = await ghPost("repos/\(scope)/actions/runs/\(runID)/cancel")
    log("cancelRun › run=\(runID) scope=\(scope) success=\(result)")
    return result
}
