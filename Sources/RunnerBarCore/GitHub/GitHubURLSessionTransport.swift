// GitHubURLSessionTransport.swift
// RunnerBarCore

import Foundation

// MARK: - Transport protocol

/// Protocol describing the full set of GitHub network operations performed by
/// `GitHubTransport`. Conforming types can be injected in place of the real
/// `URLSession`-backed implementation, enabling unit tests to run without
/// network access.
///
/// - Note: All methods mirror the existing free-function signatures in this file.
///   Default `timeout` values match the legacy free-function defaults so that
///   existing call sites require no changes when migrated.
public protocol GitHubTransportProtocol: Sendable {
    /// Fetches a single GitHub REST API page. Returns decoded `Data` on success, `nil` on any failure.
    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data?
    /// Fetches and concatenates all pages for a paginated GitHub REST endpoint.
    func apiPaginated(_ endpoint: String, timeout: TimeInterval) async -> Data?
    /// Fetches raw bytes (e.g. log files) following redirects. Returns `nil` on failure.
    func raw(_ endpoint: String, timeout: TimeInterval) async -> Data?
    /// Posts `body` to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    func post(_ endpoint: String, body: Data?, timeout: TimeInterval) async -> Data?
    /// Sends a PUT with `body` to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    func put(_ endpoint: String, body: Data, timeout: TimeInterval) async -> Data?
    /// Sends a DELETE to `endpoint`. Returns `true` on 2xx, `false` otherwise.
    func delete(_ endpoint: String, timeout: TimeInterval) async -> Bool
    /// Cancels the workflow run identified by `runID` inside `scope`.
    func cancelRun(runID: Int, scope: String) async -> Bool
    /// Replaces the labels on `runnerID` within `scope`. Returns the updated label list, or `nil`.
    func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]?
    /// Fetches a short-lived registration token for the runner identified by `scope`.
    func fetchRegistrationToken(scope: String) async -> String?
    /// Fetches a short-lived removal token for the runner identified by `scope`.
    func fetchRemovalToken(scope: String) async -> String?
    /// Removes the runner identified by `runnerID` from `scope`. Returns `true` on success.
    func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool
}

// MARK: - GitHubTransportProtocol defaults

/// Timeout-free convenience overloads for all protocol methods.
///
/// These are **distinct selectors** from the protocol requirements (no `timeout:` label),
/// so they dispatch unambiguously to the required `timeout:`-bearing methods. A mock
/// conformer that implements only the required signatures will never accidentally recurse
/// into these defaults — the call sites simply resolve to the correct concrete method.
public extension GitHubTransportProtocol {
    /// Fetches a single GitHub REST API page using the default 20 s timeout.
    func apiAsync(_ endpoint: String) async -> Data? {
        await apiAsync(endpoint, timeout: 20)
    }
    /// Fetches and concatenates all pages for a paginated endpoint using the default 60 s timeout.
    func apiPaginated(_ endpoint: String) async -> Data? {
        await apiPaginated(endpoint, timeout: 60)
    }
    /// Fetches raw bytes using the default 60 s timeout.
    func raw(_ endpoint: String) async -> Data? {
        await raw(endpoint, timeout: 60)
    }
    /// Posts `body` to `endpoint` using the default 30 s timeout.
    /// - Warning: Mock conformers must **not** add a 2-arg `post(_:body:)` override — doing so
    ///   shadows this default and prevents dispatch to the required 3-arg `post(_:body:timeout:)`.
    func post(_ endpoint: String, body: Data? = nil) async -> Data? {
        await post(endpoint, body: body, timeout: 30)
    }
    /// Sends a PUT with `body` to `endpoint` using the default 30 s timeout.
    func put(_ endpoint: String, body: Data) async -> Data? {
        await put(endpoint, body: body, timeout: 30)
    }
    /// Sends a DELETE to `endpoint` using the default 30 s timeout.
    func delete(_ endpoint: String) async -> Bool {
        await delete(endpoint, timeout: 30)
    }
}

// MARK: - GitHubTransport

/// The concrete `URLSession`-backed implementation of `GitHubTransportProtocol`.
///
/// `GitHubTransport` owns the decoder, encoder, rate-limiter, and token-provider.
/// Callers that need a real network transport use `sharedGitHubTransport`; tests
/// inject a mock conformer or construct a custom instance via
/// `init(decoder:encoder:rateLimiter:tokenProvider:)`.
///
/// **Thread safety:** `GitHubTransport` is a value type (`struct`) whose stored
/// `let` properties are all either value types (`JSONDecoder`, `JSONEncoder`) or
/// `Sendable` reference types (`any RateLimitActorProtocol`, the token closure).
/// Concurrent reads are safe; there is no mutable state.
public struct GitHubTransport: GitHubTransportProtocol {

    // MARK: - Stored properties

    /// JSON decoder — stateless after `init`, safe for concurrent reads.
    /// Kept as a stored `let` (one allocation per `GitHubTransport` instance)
    /// rather than per-call-site to avoid repeated allocations while remaining
    /// functionally identical to a local instance in every call site.
    private let decoder: JSONDecoder

    /// JSON encoder — stateless after `init`, safe for concurrent reads.
    /// Same rationale as `decoder`.
    private let encoder: JSONEncoder

    /// Rate-limit actor used to arm/clear the global back-off window.
    /// Defaults to the module-level `rateLimitActor` singleton so existing
    /// production behaviour is preserved without any call-site changes.
    private let rateLimiter: any RateLimitActorProtocol

    /// Synchronous closure that returns the current GitHub PAT, or `nil` when
    /// the user is signed out. Defaults to `githubTokenCore()` from
    /// `GitHubTransportShim` so the token pipeline is unchanged at launch.
    private let tokenProvider: @Sendable () -> String?

    // MARK: - Init

    /// Creates a `GitHubTransport` with the given dependencies.
    ///
    /// All parameters have defaults that reproduce the production behaviour,
    /// so `GitHubTransport()` is ready to use without any configuration.
    ///
    /// - Parameters:
    ///   - decoder: JSON decoder instance. Defaults to a fresh `JSONDecoder()`.
    ///   - encoder: JSON encoder instance. Defaults to a fresh `JSONEncoder()`.
    ///   - rateLimiter: Rate-limit actor. Defaults to the shared `rateLimitActor`.
    ///   - tokenProvider: Closure returning the current GitHub PAT or `nil`.
    ///     Defaults to `githubTokenCore()` from `GitHubTransportShim`.
    public init(
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        rateLimiter: some RateLimitActorProtocol = rateLimitActor,
        tokenProvider: (@Sendable () -> String?)? = nil
    ) {
        self.decoder = decoder
        self.encoder = encoder
        self.rateLimiter = rateLimiter
        self.tokenProvider = tokenProvider ?? { githubTokenCore() }
    }
}

// MARK: - GitHubTransport: core execution

/// Core execution pipeline shared by all `GitHubTransportProtocol` methods.
extension GitHubTransport {

    /// Single shared token-guard → URL-resolve → send → handle-response pipeline
    /// used by all `GitHubTransportProtocol` methods on this struct.
    ///
    /// Mirrors the module-level `urlSessionExecute` free function exactly, but
    /// reads `tokenProvider`, `rateLimiter` from `self` instead of module globals.
    ///
    /// - Parameters:
    ///   - endpoint: Relative path or absolute URL string.
    ///   - timeout: `URLRequest.timeoutInterval` for this request.
    ///   - logTag: Short prefix for all `log()` calls within the function.
    ///   - useRawAccept: When `true`, sets the raw-bytes `Accept` header instead
    ///     of the standard JSON header. Required for log endpoints that redirect to S3.
    ///   - configure: Closure applied to the pre-built `URLRequest` before sending.
    ///     Defaults to the identity closure. Must be `@Sendable`.
    @concurrent
    private func execute(
        _ endpoint: String,
        timeout: TimeInterval,
        logTag: String,
        useRawAccept: Bool = false,
        configure: @Sendable (URLRequest) -> URLRequest = { $0 }
    ) async -> ExecuteResult {
        guard let token = tokenProvider() else {
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
            // the TOCTOU window that existed with the old snapshot+clear two-hop pattern.
            await rateLimiter.clearIfNotLimited()
            let linkHeader = http.value(forHTTPHeaderField: "Link")
            return .success(data, statusCode: http.statusCode, linkHeader: linkHeader)
        } catch {
            log("\(logTag) › \(urlString) network error: \(error.localizedDescription)")
            return .networkError(error)
        }
    }
}

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

// MARK: - Private response models

/// Decoding model for the GitHub "set runner labels" PUT response.
private struct LabelsResponse: Decodable {
    /// A single runner label entry returned by the GitHub API.
    struct Label: Decodable {
        /// The display name of the runner label.
        let name: String
    }
    /// The full list of labels attached to the runner after the PUT.
    let labels: [Label]
}

// MARK: - GitHubTransport: protocol conformance

/// Conformance to ``GitHubTransportProtocol`` — all public API surface.
extension GitHubTransport {

    // MARK: apiAsync

    /// Fetches a single GitHub API page. Returns decoded `Data` on success, `nil` on any failure.
    @concurrent
    public func apiAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
        guard case .success(let data, _, _) = await execute(
            endpoint, timeout: timeout, logTag: "apiAsync"
        ) else { return nil }
        return data
    }

    // MARK: apiPaginated

    /// Fetches and concatenates all pages for a GitHub paginated endpoint.
    /// Follows `Link: <url>; rel="next"` until all pages are consumed or an error stops pagination.
    ///
    /// - Returns `nil` on auth failure (401, permission-denied 403, missing/revoked token).
    /// - Returns `nil` when a stopping condition occurs before any items are accumulated.
    /// - Returns encoded `[]` (non-nil) when the endpoint returns a valid empty-array response.
    /// - Returns partial results when pagination stops mid-way due to rate-limit or network error.
    @concurrent
    public func apiPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
        var nextURL: String? = resolveURL(endpoint)
        var allItems: [AnyJSON] = []
        var didFailAuth = false
        var didRateLimit = false
        var hadAtLeastOneSuccessfulPage = false

        pagination: while let urlString = nextURL {
            let result = await execute(
                urlString, timeout: timeout, logTag: "apiPaginated"
            )
            switch result {
            case .success(let data, _, let linkHeader):
                if let page = try? decoder.decode([AnyJSON].self, from: data) {
                    hadAtLeastOneSuccessfulPage = true
                    allItems.append(contentsOf: page)
                    nextURL = extractNextURL(from: linkHeader)
                } else {
                    log("apiPaginated › unexpected non-array response at \(urlString) — stopping pagination")
                    break pagination
                }
            case .noToken:
                didFailAuth = true
                break pagination
            case .httpError(401):
                log("apiPaginated › 401 Unauthorized — token may have been revoked, stopping pagination")
                didFailAuth = true
                break pagination
            case .httpError:
                log("apiPaginated › non-2xx error at \(urlString) — stopping pagination")
                break pagination
            case .rateLimited:
                log("apiPaginated › rate limited — \(allItems.count) items collected so far")
                didRateLimit = true
                break pagination
            case .permissionDenied:
                log("apiPaginated › permission denied at \(urlString) — stopping pagination and discarding \(allItems.count) collected items")
                didFailAuth = true
                break pagination
            case .networkError:
                log("apiPaginated › network error at \(urlString) — stopping pagination")
                break pagination
            }
        }

        if didFailAuth {
            if allItems.isEmpty {
                log("apiPaginated › auth/permission failure on first page — returning nil")
            } else {
                log("apiPaginated › auth/permission failure mid-pagination — discarding \(allItems.count) collected items")
            }
            return nil
        }
        if didRateLimit {
            if allItems.isEmpty {
                log("apiPaginated › rate limited on first page — no items collected, returning nil")
                return nil
            }
            log("apiPaginated › pagination stopped by rate limit — returning \(allItems.count) partial items")
        }
        guard hadAtLeastOneSuccessfulPage else {
            log("apiPaginated › loop ended without any successful page — returning nil")
            return nil
        }
        do {
            let encoded = try encoder.encode(allItems)
            log("apiPaginated › returning \(allItems.count) items (\(encoded.count)b)")
            return encoded
        } catch {
            log("apiPaginated › encode failed: \(error) — returning nil")
            return nil
        }
    }

    // MARK: raw

    /// Fetches raw bytes from a GitHub API endpoint that 302-redirects to S3.
    @concurrent
    public func raw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
        guard case .success(let data, _, _) = await execute(
            endpoint, timeout: timeout, logTag: "raw", useRawAccept: true
        ) else { return nil }
        log("raw › \(endpoint) → \(data.count)b")
        return data
    }

    // MARK: post

    /// Sends a POST to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    @concurrent
    @discardableResult
    public func post(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
        let result = await execute(endpoint, timeout: timeout, logTag: "post") { req in
            var request = req
            request.httpMethod = "POST"
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return request
        }
        guard case .success(let data, let statusCode, _) = result else { return nil }
        log("post › \(endpoint) → \(statusCode)")
        return data
    }

    // MARK: put

    /// Sends a PUT with `body` to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    @concurrent
    public func put(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
        let result = await execute(endpoint, timeout: timeout, logTag: "put") { req in
            var request = req
            request.httpMethod = "PUT"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        }
        guard case .success(let data, let statusCode, _) = result else { return nil }
        log("put › \(endpoint) → \(statusCode)")
        return data
    }

    // MARK: delete

    /// Sends a DELETE to `endpoint`. Returns `true` on 2xx, `false` otherwise.
    @concurrent
    @discardableResult
    public func delete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
        let result = await execute(endpoint, timeout: timeout, logTag: "delete") { req in
            var request = req
            request.httpMethod = "DELETE"
            return request
        }
        if case .success = result {
            log("delete › \(endpoint) → success")
            return true
        }
        return false
    }

    // MARK: cancelRun

    /// Cancels the workflow run identified by `runID` inside `scope`.
    @concurrent
    @discardableResult
    public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
        guard let scope = Scope.parse(scopeString) else {
            log("cancelRun › invalid scope: \(scopeString)")
            return false
        }
        guard case .repo = scope else {
            log("cancelRun › scope must be a repo (owner/name), got: \(scopeString)")
            return false
        }
        let endpoint = "\(scope.apiPrefix)/actions/runs/\(runID)/cancel"
        return await post(endpoint) != nil
    }

    // MARK: patchRunnerLabels

    /// Replaces the labels on `runnerID` within `scope`. Returns the updated label list, or `nil`.
    @concurrent
    public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
        guard let scope = Scope.parse(scopeString) else {
            log("patchRunnerLabels › invalid scope: \(scopeString)")
            return nil
        }
        let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)/labels"
        log("patchRunnerLabels › PUT \(endpoint) labels=\(labels)")
        guard let bodyData = try? encoder.encode(["labels": labels]) else {
            log("patchRunnerLabels › failed to serialise request body")
            return nil
        }
        guard let outData = await put(endpoint, body: bodyData) else {
            log("patchRunnerLabels › request failed for endpoint=\(endpoint)")
            return nil
        }
        guard let resp = try? decoder.decode(LabelsResponse.self, from: outData) else {
            let raw = String(data: outData, encoding: .utf8) ?? ""
            log("patchRunnerLabels › decode failed raw=\(raw.prefix(200))")
            return nil
        }
        let names = resp.labels.map(\.name)
        log("patchRunnerLabels › success labels=\(names)")
        return names
    }

    // MARK: fetchRegistrationToken / fetchRemovalToken

    /// Fetches a short-lived registration token for the runner identified by `scope`.
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

    // MARK: deleteRunnerByID

    /// Removes the runner identified by `runnerID` from `scope`. Returns `true` on success.
    @concurrent
    @discardableResult
    public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
        guard let scope = Scope.parse(scopeString) else {
            log("deleteRunnerByID › invalid scope: \(scopeString)")
            return false
        }
        let endpoint = "\(scope.apiPrefix)/actions/runners/\(runnerID)"
        log("deleteRunnerByID › DELETE \(endpoint) runnerID=\(runnerID)")
        let success = await delete(endpoint)
        if !success { log("deleteRunnerByID › failed for runnerID=\(runnerID)") }
        return success
    }

    // MARK: - Private helpers

    /// Requests a runner token of the given `type` (registration or removal) for `scope`.
    @concurrent
    private func fetchRunnerToken(type: String, scope: Scope, logPrefix: String) async -> String? {
        let endpoint = "\(scope.apiPrefix)/actions/runners/\(type)"
        log("\(logPrefix) › POSTing \(endpoint)")
        guard let outputData = await post(endpoint) else {
            log("\(logPrefix) › request failed for \(endpoint)")
            return nil
        }
        guard !outputData.isEmpty else {
            log("\(logPrefix) › unexpected empty body for \(endpoint) (204?)")
            return nil
        }
        struct TokenResponse: Decodable { let token: String }
        guard let resp = try? decoder.decode(TokenResponse.self, from: outputData) else {
            log("\(logPrefix) › decode failed (\(outputData.count)b)")
            return nil
        }
        return resp.token
    }
}

// MARK: - Shared default instance

/// The process-wide default `GitHubTransport` instance.
///
/// Wired with the production token provider and rate-limiter so existing free-function
/// shims below forward to real network behaviour with zero configuration.
/// Tests that need a fake transport should construct a `GitHubTransport` directly
/// (or provide a mock conformer to `GitHubTransportProtocol`) and NOT use this global.
public let sharedGitHubTransport = GitHubTransport()

// MARK: - Backward-compatibility shims
//
// The free functions below are call-site-compatible aliases for the methods on
// `GitHubTransport`. They exist only to avoid breaking all current callers while
// Items 4 and 8 of issue #1513 migrate each call site to use an injected transport.
// Remove each shim as its callers are migrated.

/// Fetches a single GitHub API page. Returns `nil` on failure.
/// - SeeAlso: ``GitHubTransport/apiAsync(_:timeout:)``
@concurrent
public func urlSessionAPIAsync(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await sharedGitHubTransport.apiAsync(endpoint, timeout: timeout)
}

/// Fetches and concatenates all pages for a paginated GitHub endpoint.
/// - SeeAlso: ``GitHubTransport/apiPaginated(_:timeout:)``
@concurrent
public func urlSessionAPIPaginated(
    _ endpoint: String,
    timeout: TimeInterval = 60
) async -> Data? {
    await sharedGitHubTransport.apiPaginated(endpoint, timeout: timeout)
}

/// Internal overload retaining the injected rateLimiter for existing unit tests.
/// ⚠️ The constructed `GitHubTransport` uses the **real** `githubTokenCore()` token provider —
/// the injected `rateLimiter` is isolated to this ephemeral instance and does not share state
/// with `sharedGitHubTransport`. Verify paginated tests are not token-sensitive before Item 8 migration.
/// - Note: TODO(#1513-cleanup): retire when Items 4 and 8 migrate callers to `GitHubTransportProtocol` mocks.
@concurrent
func urlSessionAPIPaginated(
    _ endpoint: String,
    timeout: TimeInterval = 60,
    rateLimiter: some RateLimitActorProtocol
) async -> Data? {
    let transport = GitHubTransport(rateLimiter: rateLimiter)
    return await transport.apiPaginated(endpoint, timeout: timeout)
}

/// Fetches raw bytes (log endpoints). Returns `nil` on failure.
/// - SeeAlso: ``GitHubTransport/raw(_:timeout:)``
@concurrent
public func urlSessionRaw(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    await sharedGitHubTransport.raw(endpoint, timeout: timeout)
}

/// Sends a POST to `endpoint`. Returns response `Data` or `nil`.
/// - SeeAlso: ``GitHubTransport/post(_:body:timeout:)``
@concurrent
@discardableResult
public func urlSessionPost(_ endpoint: String, body: Data? = nil, timeout: TimeInterval = 30) async -> Data? {
    await sharedGitHubTransport.post(endpoint, body: body, timeout: timeout)
}

/// Sends a PUT with `body` to `endpoint`. Returns response `Data` or `nil`.
/// - SeeAlso: ``GitHubTransport/put(_:body:timeout:)``
@concurrent
public func urlSessionPut(_ endpoint: String, body: Data, timeout: TimeInterval = 30) async -> Data? {
    await sharedGitHubTransport.put(endpoint, body: body, timeout: timeout)
}

/// Sends a DELETE to `endpoint`. Returns `true` on 2xx.
/// - SeeAlso: ``GitHubTransport/delete(_:timeout:)``
@concurrent
@discardableResult
public func urlSessionDelete(_ endpoint: String, timeout: TimeInterval = 30) async -> Bool {
    await sharedGitHubTransport.delete(endpoint, timeout: timeout)
}

/// Thin GET alias used widely across the module.
/// - SeeAlso: ``GitHubTransport/apiAsync(_:timeout:)``
nonisolated(nonsending)
public func ghAPI(_ endpoint: String, timeout: TimeInterval = 20) async -> Data? {
    await urlSessionAPIAsync(endpoint, timeout: timeout)
}

/// Fire-and-forget POST alias. Returns `true` on 2xx.
/// - SeeAlso: ``GitHubTransport/post(_:body:timeout:)``
@concurrent
@discardableResult
public func ghPost(_ endpoint: String) async -> Bool {
    let result = await sharedGitHubTransport.post(endpoint)
    let success = result != nil
    log("ghPost › \(endpoint) success=\(success)")
    return success
}

/// Deregisters a runner from GitHub via DELETE.
/// - SeeAlso: ``GitHubTransport/deleteRunnerByID(scope:runnerID:)``
@concurrent
@discardableResult
public func deleteRunnerByID(scope scopeString: String, runnerID: Int) async -> Bool {
    await sharedGitHubTransport.deleteRunnerByID(scope: scopeString, runnerID: runnerID)
}

/// Replaces all custom labels on a runner.
/// - SeeAlso: ``GitHubTransport/patchRunnerLabels(scope:runnerID:labels:)``
@concurrent
public func patchRunnerLabels(scope scopeString: String, runnerID: Int, labels: [String]) async -> [String]? {
    await sharedGitHubTransport.patchRunnerLabels(scope: scopeString, runnerID: runnerID, labels: labels)
}

/// Fetches a runner registration token.
/// - SeeAlso: ``GitHubTransport/fetchRegistrationToken(scope:)``
@concurrent
public func fetchRegistrationToken(scope scopeString: String) async -> String? {
    await sharedGitHubTransport.fetchRegistrationToken(scope: scopeString)
}

/// Fetches a runner removal token.
/// - SeeAlso: ``GitHubTransport/fetchRemovalToken(scope:)``
@concurrent
public func fetchRemovalToken(scope scopeString: String) async -> String? {
    await sharedGitHubTransport.fetchRemovalToken(scope: scopeString)
}

/// Cancels a workflow run.
/// - SeeAlso: ``GitHubTransport/cancelRun(runID:scope:)``
@concurrent
@discardableResult
public func cancelRun(runID: Int, scope scopeString: String) async -> Bool {
    await sharedGitHubTransport.cancelRun(runID: runID, scope: scopeString)
}
