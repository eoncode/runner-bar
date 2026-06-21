// GitHubURLSessionTransport.swift
// RunnerBarCore

import Foundation

/// Shared decoder — intentionally kept as a module-level singleton rather than
/// replaced with per-call-site `let decoder = JSONDecoder()`. The decoder is
/// stateless after initialisation and safe for concurrent reads (no mutable
/// stored properties that interact with `decode`). Keeping it shared avoids
/// one allocation per call while being functionally identical to a local
/// instance in every call site.
///
/// - Note: Issue #1477 was originally scoped to replace the encoder with per-call-site
///   local instances. After review, both the encoder and decoder are deliberately
///   retained as shared: both are stateless after initialisation so the allocation
///   savings outweigh the cosmetic benefit of locality.
private let sharedDecoder = JSONDecoder()

/// Shared encoder — intentionally kept as a module-level singleton rather than
/// replaced with per-call-site `let encoder = JSONEncoder()`. The encoder is
/// stateless after initialisation and safe for concurrent reads (no mutable
/// stored properties that interact with `encode`). Keeping it shared avoids
/// one allocation per call while being functionally identical to a local
/// instance in every call site.
/// Used by `urlSessionAPIPaginated` (page accumulation) and `patchRunnerLabels` (label body).
///
/// - Note: Issue #1477 was originally scoped to replace this with per-call-site local
///   instances. After review, the shared approach is deliberately retained: `JSONEncoder`
///   is stateless after initialisation so the allocation savings outweigh the cosmetic
///   benefit of locality. #1477 is closed as resolved by this documented decision.
private let sharedEncoder = JSONEncoder()

// MARK: - Shared execution core

/// The result of a single URLSession round-trip through `urlSessionExecute`.
private enum ExecuteResult {
    /// 2xx response with optional body data (empty `Data()` for 204 No Content).
    ///
    /// `linkHeader` carries the raw `Link:` response header value used by paginated callers
    /// to discover the next-page URL. Non-paginated callers (e.g. `urlSessionAPIAsync`,
    /// `urlSessionPost`) always receive `nil` here and destructure with `_` — this is
    /// intentional. A split into `success` / `successPaginated` was considered but deferred:
    /// the single case keeps `urlSessionExecute` callers uniform and the `nil` default is
    /// always correct for endpoints that do not emit a `Link` header.
    case success(Data, statusCode: Int, linkHeader: String?)
    /// No GitHub token is currently available — the token provider returned `nil`.
    /// Distinct from `.networkError` and `.httpError(401)` so callers can treat
    /// "never had a token" separately from "token was valid but rejected by GitHub".
    ///
    /// - Note: Non-paginated callers (`urlSessionAPIAsync`, `urlSessionPost`,
    ///   `urlSessionPut`, `urlSessionRaw`) use `guard case .success` and therefore
    ///   treat `.noToken` identically to every other non-success result — a `nil`
    ///   return. Only `urlSessionAPIPaginated` pattern-matches this case explicitly,
    ///   to discard any partially collected items and return `nil` rather than partial
    ///   results. If you add a new call site that needs to distinguish "never had a
    ///   token" from other failures, match `.noToken` directly instead of relying on
    ///   the `guard case .success` collapse.
    case noToken
    /// Non-2xx response that is not a rate-limit or permission error; the request failed.
    case httpError(Int)
    /// 403 or 429 that triggered the rate-limit actor (genuine rate limit).
    /// Covers both the case where this request freshly armed the actor and the case
    /// where the actor was already armed by a concurrent caller — callers treat both
    /// identically (back off and retry).
    case rateLimited
    /// 403 that did NOT trigger the rate-limit actor — token scope, revoked PAT, or
    /// repo access denial. The actor is not armed; the token needs attention.
    case permissionDenied
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
///   - rateLimiter: The rate-limit actor to read from and write to. Defaults to the
///     module-level `rateLimitActor`; tests pass a `SpyRateLimitActor` for determinism.
///   - configure: A closure applied to the pre-built `URLRequest` just before it is sent.
///     Use this to set `httpMethod`, `httpBody`, or additional headers. The closure receives
///     the base request and must return the mutated copy; the default is the identity closure.
///     Must be `@Sendable`: `urlSessionExecute` is `@concurrent` and all parameters crossing
///     into the cooperative thread pool must satisfy the `Sendable` requirement.
@concurrent
private func urlSessionExecute(
    _ endpoint: String,
    timeout: TimeInterval,
    logTag: String,
    useRawAccept: Bool = false,
    rateLimiter: some RateLimitActorProtocol = rateLimitActor,
    configure: @Sendable (URLRequest) -> URLRequest = { $0 }
) async -> ExecuteResult {
    // Called exactly once per call; paginated tests rely on this call-count.
    guard let token = githubTokenCore() else {
        log("\(logTag) › no token available")
        return .noToken
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
            // Use the Bool return value from handleRateLimitResponse to classify
            // this response directly from its headers — never from the actor state.
            // Reading the actor after the call is a TOCTOU: a prior concurrent
            // request may have already armed the actor, causing a plain
            // permission-denied 403 (no rate-limit headers) to be misclassified
            // as .rateLimited instead of .permissionDenied.
            let wasRateLimited = await handleRateLimitResponse(
                statusCode: http.statusCode, data, response: http,
                endpoint: urlString, rateLimiter: rateLimiter
            )
            return wasRateLimited ? .rateLimited : .permissionDenied
        }
        guard (200..<300).contains(http.statusCode) else {
            logErrorBody(data, endpoint: urlString, status: http.statusCode)
            return .httpError(http.statusCode)
        }
        // Clear the rate-limit flag after a successful 2xx response, but only
        // when the actor is not currently limited. A single `clearIfNotLimited()`
        // call performs the check and the clear in one atomic actor hop, eliminating
        // the TOCTOU window that existed with the old snapshot+clear two-hop pattern:
        //
        //   OLD (racy): let snap = await rateLimiter.snapshot()   // hop 1
        //               if !snap.isLimited { await rateLimiter.clear() }  // hop 2
        //
        // Between hop 1 and hop 2 a concurrent request could arm the actor, and the
        // subsequent unconditional clear() would erase an active rate-limit window.
        //
        // The intentional clear site (RunnerStore.fetch() calls clearGhRateLimit() at
        // the start of each poll cycle) bypasses this guard by design — it continues
        // to call clear() directly.
        await rateLimiter.clearIfNotLimited()
        let linkHeader = http.value(forHTTPHeaderField: "Link")
        return .success(data, statusCode: http.statusCode, linkHeader: linkHeader)
    } catch {
        log("\(logTag) › \(urlString) network error: \(error.localizedDescription)")
        return .networkError(error)
    }
}

// MARK: - Async GET (primary transport)

/// Fetches a single GitHub API page using `URLSession.data(for:)` async/await.
///
/// Intentionally internal to the module: this is a stable call site consumed by `RunnerStore`
/// and other module-level consumers across files. The underlying `urlSessionExecute` remains
/// private to this file.
@concurrent
public func urlSessionAPIAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    guard case .success(let data, _, _) = await urlSessionExecute(
        endpoint, timeout: timeout, logTag: "urlSessionAPIAsync"
    ) else { return nil }
    return data
}

/// Fetches and concatenates all pages for a GitHub paginated endpoint.
/// Follows `Link: <url>; rel="next"` until all pages are consumed or an error stops pagination.
///
/// Delegates the per-page token-guard → request-build → rate-limit-check → response-handle
/// pipeline to `urlSessionExecute`, keeping only the accumulation loop and the
/// partial-results return path here.
///
/// - Returns `nil` on auth failure (401, permission-denied 403, missing/revoked token).
/// - Returns `nil` when a stopping condition occurs before any items are accumulated
///   (e.g. rate-limited or network error on the very first page).
/// - Returns encoded `[]` (non-nil) when the endpoint returns a valid empty-array
///   response. Callers can decode this to an empty array and distinguish "confirmed
///   empty" from "something went wrong" (nil).
/// - Returns partial results (not nil) if at least one page was accumulated before
///   pagination was stopped by a genuine rate limit.
/// - Returns partial results (not nil) if at least one page was accumulated before
///   pagination was stopped by a transient network error (e.g. timeout, no connectivity).
///   This distinguishes recoverable mid-pagination interruptions from auth failures,
///   which always discard all collected items.
/// - Returns partial results (not nil) if at least one page was accumulated before
///   pagination was stopped by a non-auth HTTP error (e.g. 404, 410, 503). Only auth
///   failures (401, permission-denied 403, no/revoked token) discard all collected items;
///   non-auth HTTP errors are treated as recoverable mid-pagination interruptions.
///   Callers that need to distinguish total failure from partial success should check
///   the result length relative to their expected total.
/// - Note: `extractNextURL(from: nil)` returns `nil`, so passing a non-paginated endpoint
///   (which returns no `Link` header) terminates the loop naturally after the first page.
@concurrent
public func urlSessionAPIPaginated(
    _ endpoint: String,
    timeout: TimeInterval = 60
) async -> Data? {
    await urlSessionAPIPaginated(endpoint, timeout: timeout, rateLimiter: rateLimitActor)
}

/// Internal implementation of ``urlSessionAPIPaginated(_:timeout:)`` that accepts an
/// explicit `rateLimiter` dependency, enabling injection during unit tests without
/// exposing the parameter on the public API.
///
/// All semantics (partial results, auth-failure nil, etc.) are identical to the
/// public overload — see its documentation for full details.
@concurrent
func urlSessionAPIPaginated(
    _ endpoint: String,
    timeout: TimeInterval = 60,
    rateLimiter: some RateLimitActorProtocol
) async -> Data? {
    var nextURL: String? = resolveURL(endpoint)
    var allItems: [AnyJSON] = []
    // Both auth failure (401, no-token) and permission denial (403 non-rate-limit)
    // discard all collected items and return nil. They are collapsed into a single
    // flag because the post-loop behaviour is identical; the log messages below
    // retain the distinction so operators can tell them apart.
    var didFailAuth = false
    var didRateLimit = false
    // Tracks whether at least one page decoded successfully. Used in the post-loop
    // guard to distinguish a legitimate empty-array response (200 []) — which should
    // return encoded empty Data, not nil — from a loop that never got any successful page.
    var hadAtLeastOneSuccessfulPage = false

    pagination: while let urlString = nextURL {
        let result = await urlSessionExecute(
            urlString, timeout: timeout, logTag: "urlSessionAPIPaginated",
            rateLimiter: rateLimiter
        )
        switch result {
        case .success(let data, _, let linkHeader):
            if let page = try? sharedDecoder.decode([AnyJSON].self, from: data) {
                hadAtLeastOneSuccessfulPage = true
                allItems.append(contentsOf: page)
                nextURL = extractNextURL(from: linkHeader)
            } else {
                log("urlSessionAPIPaginated › unexpected non-array response at \(urlString) — stopping pagination")
                break pagination
            }
        case .noToken:
            // Token was nil when urlSessionExecute ran its `guard let token = githubTokenCore()`
            // at the top of the function. This is the sole mechanism for the mid-pagination
            // token-revocation path: `urlSessionExecute` returns `.noToken`, never
            // `.networkError(URLError(.userAuthenticationRequired))`. The
            // `.userAuthenticationRequired` URLError code is produced by URLSession only for
            // HTTP Basic/Digest auth challenges and is never emitted on the GitHub Bearer-token
            // path. An arm matching that code was removed from this switch in a prior commit;
            // do not re-add it.
            //
            // Treat as auth failure: discard partial results and return nil, matching the
            // documented contract. Post-loop logging distinguishes first-page vs mid-pagination.
            didFailAuth = true
            break pagination
        case .httpError(401):
            log("urlSessionAPIPaginated › 401 Unauthorized — token may have been revoked, stopping pagination")
            didFailAuth = true
            break pagination
        case .httpError:
            // Non-auth HTTP errors (404, 410, 503, etc.) stop pagination but do
            // NOT discard partial items — the items collected from earlier pages
            // are returned. This is a deliberate design choice: only auth failures
            // (no-token, 401, permission-denied 403) discard all items. Callers
            // that need to distinguish total failure from partial success should
            // check the result length relative to their expected total.
            log("urlSessionAPIPaginated › non-2xx error at \(urlString) — stopping pagination")
            break pagination
        case .rateLimited:
            log("urlSessionAPIPaginated › rate limited — \(allItems.count) items collected so far")
            didRateLimit = true
            break pagination
        case .permissionDenied:
            // 403 that did not arm the rate-limit actor — token scope, revoked PAT, or
            // repo access denial. Treated identically to an auth failure: discard all
            // collected items and return nil. Folded into didFailAuth (not a separate flag)
            // because the post-loop behaviour is the same; post-loop logging covers it.
            log("urlSessionAPIPaginated › permission denied at \(urlString) — stopping pagination and discarding \(allItems.count) collected items")
            didFailAuth = true
            break pagination
        case .networkError:
            log("urlSessionAPIPaginated › network error at \(urlString) — stopping pagination")
            break pagination
        }
    }

    if didFailAuth {
        if allItems.isEmpty {
            log("urlSessionAPIPaginated › auth/permission failure on first page — no items collected, returning nil")
        } else {
            log("urlSessionAPIPaginated › auth/permission failure mid-pagination — discarding \(allItems.count) partial items")
        }
        return nil
    }
    if didRateLimit {
        if allItems.isEmpty {
            log("urlSessionAPIPaginated › rate limited on first page — no items collected, returning nil")
            return nil
        }
        log("urlSessionAPIPaginated › pagination stopped by rate limit — returning \(allItems.count) partial items")
    }
    // Auth failure and rate-limited-on-first-page both return nil explicitly above.
    // For all other paths:
    //   - hadAtLeastOneSuccessfulPage && allItems.isEmpty → server returned 200 [], encode as "[]"
    //   - hadAtLeastOneSuccessfulPage && !allItems.isEmpty → partial results, encode normally
    //   - !hadAtLeastOneSuccessfulPage → loop never got a successful page (e.g. 404 on first page)
    guard hadAtLeastOneSuccessfulPage else {
        log("urlSessionAPIPaginated › loop ended without any successful page — returning nil")
        return nil
    }
    do {
        let encoded = try sharedEncoder.encode(allItems)
        log("urlSessionAPIPaginated › returning \(allItems.count) items (\(encoded.count)b)")
        return encoded
    } catch {
        log("urlSessionAPIPaginated › encode failed: \(error) — returning nil")
        return nil
    }
}

// MARK: - Raw async (log endpoints)

/// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3.
///
/// - Note: This function uses `makeRawRequest` which sets `Accept: application/vnd.github.v3.raw`.
///   Apple's URLSession strips the `Authorization` header before following cross-origin
///   redirects (RFC 7235), so the Bearer token is never forwarded to S3.
///   See `makeRawRequest` in `GitHubRequestBuilder.swift` for full details.
@concurrent
public func urlSessionRaw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    guard case .success(let data, _, _) = await urlSessionExecute(
        endpoint, timeout: timeout, logTag: "urlSessionRaw", useRawAccept: true
    ) else { return nil }
    log("urlSessionRaw › \(endpoint) → \(data.count)b")
    return data
}

// MARK: - POST / DELETE / PUT (mutation)

/// Sends a POST to the given GitHub API endpoint.
///
/// Intentionally internal to the module: backs `ghPost` and the runner mutation helpers below,
/// all of which are called from outside this file.
/// - Returns: Response body on 2xx (`Data()` for 204 No Content), `nil` on failure.
@concurrent
@discardableResult
public func urlSessionPost(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    let result = await urlSessionExecute(endpoint, timeout: timeout, logTag: "urlSessionPost") { req in
        var request = req
        request.httpMethod = "POST"
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    guard case .success(let data, let statusCode, _) = result else { return nil }
    log("urlSessionPost › \(endpoint) → \(statusCode)")
    return data
}

/// Sends a PUT to the given GitHub API endpoint with a JSON body.
/// - Returns: Response body on 2xx, `nil` on failure.
@concurrent
public func urlSessionPut(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    let result = await urlSessionExecute(endpoint, timeout: timeout, logTag: "urlSessionPut") { req in
        var request = req
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    guard case .success(let data, let statusCode, _) = result else { return nil }
    log("urlSessionPut › \(endpoint) → \(statusCode)")
    return data
}

/// Sends a DELETE to the given GitHub API endpoint.
/// - Returns: `true` on 2xx, `false` on any failure.
@concurrent
@discardableResult
public func urlSessionDelete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    let result = await urlSessionExecute(endpoint, timeout: timeout, logTag: "urlSessionDelete") { req in
        var request = req
        request.httpMethod = "DELETE"
        return request
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
///
/// Uses `nonisolated(nonsending)` rather than `@concurrent`: this function has no work
/// before its first suspension and immediately delegates to the already-`@concurrent`
/// `urlSessionAPIAsync`. Caller-context inheritance is always correct here; a
/// cooperative-pool hop would be redundant.
///
/// - Note: Safe to call from `@MainActor` because `urlSessionAPIAsync` is `@concurrent`
///   and will move execution to the cooperative thread pool at the first `await`.
///   Do not perform heavy synchronous work before this call from a `@MainActor` context.
///
/// - IMPORTANT: This function must remain a pure pass-through with no synchronous work
///   before the `await`. If any guard, log, or computation is ever added before the first
///   suspension, this annotation must be upgraded to `@concurrent`.
nonisolated(nonsending)
public func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await urlSessionAPIAsync(endpoint, timeout: timeout)
}

// MARK: - Runner mutation helpers

/// Directly deregisters a runner from GitHub via DELETE.
/// - Returns: `true` on success, `false` if the scope is invalid or the request fails.
@concurrent
@discardableResult
public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
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
/// - Returns: The updated label names on success, `nil` on any failure.
@concurrent
@discardableResult
public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    guard let scope = Scope.parse(scopeString) else {
        log("patchRunnerLabels › invalid scope: \(scopeString)")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
    log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)")
    guard let bodyData = try? sharedEncoder.encode(["labels": labels]) else {
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
@concurrent
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
@concurrent
public func fetchRegistrationToken(scope scopeString: String) async -> String? {
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
@concurrent
public func fetchRemovalToken(scope scopeString: String) async -> String? {
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
///
/// Uses `@concurrent` because this function has post-suspension work (nil-check + log)
/// that must run on the cooperative thread pool regardless of the caller's executor.
/// Unlike the pure-delegate wrapper `ghAPI`, this function is not a straight pass-through
/// and therefore does not qualify for `nonisolated(nonsending)`.
@concurrent
@discardableResult
public func ghPost(_ endpoint: String) async -> Bool {
    let result = await urlSessionPost(endpoint)
    let success = result != nil
    log("ghPost › \(endpoint) success=\(success)")
    return success
}

/// Cancels a workflow run via the GitHub Actions API.
/// Intentionally repo-only: the GitHub Actions cancel endpoint
/// (`/repos/{owner}/{repo}/actions/runs/{run_id}/cancel`) is scoped to repositories.
/// Org/enterprise-level cancel is not uniformly supported by the API.
/// Update this guard if org-scope cancel support is added in a future GitHub API version.
/// - Returns: `true` if the cancellation request succeeded.
@concurrent
@discardableResult
public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    guard let scope = Scope.parse(scopeString) else {
        log("cancelRun › invalid scope: \(scopeString)")
        return false
    }
    // Intentionally repo-only: see function doc above.
    guard case .repo = scope else {
        log("cancelRun › scope must be a repo (owner/name), got: \(scopeString)")
        return false
    }
    let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/cancel"
    let result = await ghPost(endpoint)
    log("cancelRun › run=\(runID) scope=\(scopeString) success=\(result)")
    return result
}
