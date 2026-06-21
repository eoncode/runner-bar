// GitHubTransportPaginatedTests.swift
// RunnerBarCoreTests
//
// Integration tests for urlSessionAPIPaginated.
// Uses URLProtocol stubbing + configureGHToken + SpyRateLimitActor to exercise
// the real pagination loop, rate-limit partial-return, and auth-abort logic.
//
// @Suite(.serialized) is required: paginatedReturnsNilWhenNoToken and
// paginatedReturnsNilWhenTokenRevokedMidPagination mutate the shared module-level
// token provider, and each test calls StubURLProtocol.reset() on the shared stub
// registry. Swift Testing runs struct suites concurrently by default; without
// serialization these two pieces of shared global state race.
//
// The suite is a `final class` (not a struct) so that `deinit` is available to
// call URLProtocol.unregisterClass. Without unregistration, StubURLProtocol
// remains registered on URLSession.shared after the suite completes and can
// intercept requests in unrelated test files that run in the same process.
//
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - StubURLProtocol

/// A URLProtocol subclass that serves pre-registered per-URL responses.
/// Register stubs before each test; the registry is cleared at the top of each test.
///
/// - Note: `@unchecked Sendable` is intentional. The `stubs` dictionary is
///   guarded by `NSLock` on every read and write, making concurrent access
///   safe. `@unchecked` is required because `URLProtocol` predates Swift
///   concurrency and does not conform to `Sendable` itself. This type is
///   test-support only — P4's "no @unchecked Sendable in production types"
///   does not apply here.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// A single canned response for one URL.
    struct Stub {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
    }

    /// A stub that produces a URLError instead of an HTTP response.
    struct ErrorStub {
        let error: URLError
    }

    // `nonisolated(unsafe)` — the two stored `var` properties are manually protected by
    // `lock` below; Swift 6 strict concurrency requires the annotation for static stored
    // properties on Sendable types that are not actor-isolated.
    // The `lock` constant itself does not need the annotation: `NSLock` is already
    // `Sendable` and immutable after initialisation.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) private static var errorStubs: [String: ErrorStub] = [:]

    static func register(_ stub: Stub, for url: String) {
        lock.withLock { stubs[url] = stub }
    }

    static func registerError(_ stub: ErrorStub, for url: String) {
        lock.withLock { errorStubs[url] = stub }
    }

    static func reset() {
        lock.withLock {
            stubs = [:]
            errorStubs = [:]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        let key = request.url?.absoluteString ?? ""
        return lock.withLock { stubs[key] != nil || errorStubs[key] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""

        // Error stub takes priority.
        if let errorStub = StubURLProtocol.lock.withLock({ StubURLProtocol.errorStubs[key] }) {
            client?.urlProtocol(self, didFailWithError: errorStub.error)
            return
        }

        let stub = StubURLProtocol.lock.withLock { StubURLProtocol.stubs[key] }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helpers

/// Encodes `[[String: String]]` to AnyJSON-compatible JSON Data.
private func jsonPage(_ items: [[String: String]]) -> Data {
    (try? JSONEncoder().encode(items.map { $0.mapValues { AnyJSON.string($0) } })) ?? Data()
}

/// Decodes a JSON Data blob back to `[[String: AnyJSON]]` for assertion.
private func decodeItems(_ data: Data?) -> [[String: AnyJSON]]? {
    guard let data else { return nil }
    return try? JSONDecoder().decode([[String: AnyJSON]].self, from: data)
}

/// Trailing-slash base URL derived from `GitHubConstants.apiBase`.
/// All stub URL construction uses this so that if apiBase ever changes
/// (e.g. GHE support), test URLs stay in sync automatically.
private let apiBase = GitHubConstants.apiBase + "/"

// MARK: - GitHubTransportPaginatedTests

/// Integration tests for `urlSessionAPIPaginated`.
///
/// Strategy: register `StubURLProtocol` on `URLSession.shared`'s configuration,
/// inject a real token via `configureGHToken`, and inject a `SpyRateLimitActor`
/// to control and observe rate-limit state. Each test calls `urlSessionAPIPaginated`
/// directly — the real pagination loop runs every time.
///
/// `.serialized` is required because this suite mutates two pieces of shared global
/// state: the module-level token provider (`configureGHToken`) and the
/// `StubURLProtocol` stub registry (`reset()`). Without serialization, Swift Testing
/// runs all tests concurrently and these mutations race.
///
/// The suite is a `final class` so that `deinit` is available to call
/// `URLProtocol.unregisterClass`. Swift Testing supports class-based suites;
/// `@Suite` and `@Test` behave identically to the struct form.
@Suite("GitHubTransportPaginated", .serialized)
final class GitHubTransportPaginatedTests {

    init() {
        // Register stub protocol and a valid token before every test.
        URLProtocol.registerClass(StubURLProtocol.self)
        configureGHToken { "test-token" }
    }

    deinit {
        // Unregister so StubURLProtocol does not intercept requests in other
        // test suites that run in the same process after this suite completes.
        URLProtocol.unregisterClass(StubURLProtocol.self)
        // Reset the token provider to its default (nil) so that unrelated test
        // suites running in the same process do not accidentally inherit
        // "test-token" and issue live authenticated requests via githubTokenCore().
        configureGHToken { nil }
    }

    // MARK: - Happy path: two-page accumulation

    /// Two pages linked via `Link: rel="next"` are fetched and combined.
    ///
    /// Verifies: pagination loop follows the Link header and `allItems` is
    /// correctly accumulated across both pages.
    @Test func paginatedHappyPathAccumulatesTwoPages() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1", "name": "runner-a"]])
        let page2Data = jsonPage([["id": "2", "name": "runner-b"]])

        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        StubURLProtocol.register(.init(
            data: page2Data,
            statusCode: 200,
            headers: [:]
        ), for: page2URL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        let items = decodeItems(result)
        #expect(items?.count == 2)
        #expect(items?[0]["id"] == .string("1"))
        #expect(items?[1]["id"] == .string("2"))
        // A successful run must clear any previously-armed rate limit.
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
    }

    // MARK: - Valid empty-array response returns non-nil

    /// A 200 response with a valid empty-array body (`[]`) must return non-nil
    /// so callers can distinguish "confirmed zero items" from a failure (nil).
    ///
    /// Regression guard for the former `guard !allItems.isEmpty else { return nil }`
    /// which made a legitimate empty endpoint (e.g. an org with no registered runners)
    /// indistinguishable from an auth failure at the call site. If the store falls back
    /// to cached data on nil, a zero-runner response would permanently show stale entries.
    ///
    /// Verifies:
    /// - `result != nil` — a valid 200 [] must not be collapsed to a failure
    /// - `items` decodes to an empty array (not nil, not a non-empty array)
    @Test func paginatedReturnsEmptyArrayOnValidEmptyResponse() async {
        StubURLProtocol.reset()
        let pageURL = "\(apiBase)orgs/test/actions/runners"

        // Valid 200 with an empty JSON array — e.g. org has no registered runners.
        StubURLProtocol.register(.init(
            data: jsonPage([]),
            statusCode: 200,
            headers: [:]
        ), for: pageURL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Must be non-nil: a valid empty response is distinguishable from a failure.
        #expect(result != nil)
        // Must decode to an empty array, not nil.
        let items = decodeItems(result)
        #expect(items != nil)
        #expect(items?.count == 0)
    }

    // MARK: - Non-array body stops pagination gracefully

    /// A 200 response with a non-array JSON body stops pagination and returns
    /// items collected so far (not nil, not a crash).
    ///
    /// Verifies: the labeled `break pagination` on the decode-failure path exits
    /// the while loop correctly (regression guard for the unlabeled-break bug).
    @Test func paginatedStopsOnNonArrayBody() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1"]])
        // Non-array body on page 2 — e.g. a GitHub error object.
        let badData = "{\"message\":\"unexpected\"}".data(using: .utf8)!

        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        StubURLProtocol.register(.init(
            data: badData,
            statusCode: 200,
            headers: [:]
        ), for: page2URL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Page 1 was accumulated before the bad page stopped things.
        let items = decodeItems(result)
        #expect(items?.count == 1)
        #expect(items?[0]["id"] == .string("1"))
    }

    // MARK: - Single-page (no Link header) happy path

    /// A single page with no `Link: rel="next"` header returns just that page's items.
    ///
    /// Verifies: `extractNextURL(from: nil)` returns `nil`, terminating the pagination
    /// loop after the first page. This is the common case for endpoints that return
    /// all results in one response.
    @Test func paginatedSinglePageReturnsItems() async {
        StubURLProtocol.reset()
        let pageURL = "\(apiBase)orgs/test/actions/runners"

        // No Link header — just a single page.
        StubURLProtocol.register(.init(
            data: jsonPage([["id": "1", "name": "runner-a"], ["id": "2", "name": "runner-b"]]),
            statusCode: 200,
            headers: [:]
        ), for: pageURL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        let items = decodeItems(result)
        #expect(items?.count == 2)
        #expect(items?[0]["id"] == .string("1"))
        #expect(items?[1]["id"] == .string("2"))
    }

    // MARK: - Rate-limit on first page returns nil

    /// A 429 on the very first page with zero items accumulated must return nil.
    ///
    /// Verifies the documented contract:
    /// "Returns nil when a stopping condition occurs before any items are accumulated
    /// (e.g. rate-limited or network error on the very first page)."
    @Test func paginatedReturnsNilOnRateLimitFirstPage() async {
        StubURLProtocol.reset()
        let pageURL = "\(apiBase)orgs/test/actions/runners"

        StubURLProtocol.register(.init(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]
        ), for: pageURL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        #expect(result == nil)
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled)
        // clear() must NOT be called — no 2xx page succeeded before the 429.
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled == false)
    }

    // MARK: - Rate-limit partial return

    /// A genuine 429 rate-limit mid-pagination arms the spy and returns partial items.
    ///
    /// Verifies: `.rateLimited` path returns collected items (not nil), and
    /// `SpyRateLimitActor.setCalled` is true — confirming the injected actor
    /// (not the global) was armed.
    ///
    /// - Note: 429 is chosen over 403 because the GitHub API uses 429 exclusively
    ///   for genuine rate limits. The stub includes a `Retry-After: 60` header so
    ///   `handleRateLimitResponse` arms the actor via the `Retry-After` path (the
    ///   primary path), not the `X-RateLimit-Reset` fallback. Do not swap this to a
    ///   403 without also verifying the spy's `set(resetAt:)` is still called.
    @Test func paginatedReturnsPartialResultsOnRateLimit() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        // 429 on page 2 — genuine rate limit. Retry-After: 60 arms the actor via
        // the primary header path (not the X-RateLimit-Reset fallback).
        StubURLProtocol.register(.init(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]
        ), for: page2URL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Partial results from page 1 must be returned.
        let items = decodeItems(result)
        #expect(items?.count == 1)
        #expect(result != nil)
        // The injected spy — not the global — must have been armed.
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled)
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
        // clear() IS called after page 1 success (2xx response clears the limiter).
    }

    // MARK: - Transient network error returns partial results

    /// A transient network error (e.g. timeout) mid-pagination must return the
    /// items collected so far — not nil.
    ///
    /// Verifies the documented contract:
    /// "Returns partial results (not nil) if pagination is stopped by a transient
    /// network error."
    ///
    /// Mechanism: page 1 succeeds (200 + Link header). Page 2 throws
    /// `URLError(.timedOut)` via `StubURLProtocol.registerError`. The pagination
    /// loop matches `.networkError`, exits via `break pagination`, and returns
    /// `allItems` — which contains the one item from page 1.
    ///
    /// Three assertions:
    /// - `result != nil` — partial items are returned, not discarded
    /// - `items.count == 1` — only the page-1 item is present
    /// - `spy.setCalled == false` — a network error must never arm the rate limiter
    @Test func paginatedReturnsPartialResultsOnTransientNetworkError() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        // Page 2 throws a transient network error — simulates a timeout mid-pagination.
        StubURLProtocol.registerError(
            .init(error: URLError(.timedOut)),
            for: page2URL
        )

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Partial item from page 1 must be returned — not nil.
        #expect(result != nil)
        let items = decodeItems(result)
        #expect(items?.count == 1)
        // clear() IS called after page 1 success (2xx response clears the limiter).
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
        // A transient network error must never arm the rate-limit actor.
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled == false)
    }

    // MARK: - Permission-denied discards all items

    /// A plain 403 with no rate-limit headers is permission-denied: partial items
    /// are discarded and nil is returned. The spy must NOT be armed.
    ///
    /// Verifies: `.permissionDenied` path returns nil, and `SpyRateLimitActor.setCalled`
    /// is false — confirming the injected actor distinguishes rate-limit from perm-denied.
    @Test func paginatedReturnsNilOnPermissionDenied() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1"]])

        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        // Plain 403, no Retry-After, no X-RateLimit-Remaining: 0 — permission error.
        StubURLProtocol.register(.init(
            data: "{\"message\":\"Must have admin rights\"}".data(using: .utf8)!,
            statusCode: 403,
            headers: [:]
        ), for: page2URL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        #expect(result == nil)
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled == false)
        // clear() IS called after page 1 success (2xx response clears the limiter).
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
    }

    // MARK: - 401 auth failure discards all items

    /// A 401 mid-pagination must discard all partially collected items and return nil.
    ///
    /// Verifies: `.httpError(401)` triggers `didFailAuth`, and the auth-abort
    /// semantics introduced in the #1476 refactor are preserved.
    @Test func paginatedReturnsNilOnAuthFailure401() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        StubURLProtocol.register(.init(
            data: "{\"message\":\"Bad credentials\"}".data(using: .utf8)!,
            statusCode: 401,
            headers: [:]
        ), for: page2URL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Partial item from page 1 must be discarded — nil returned.
        #expect(result == nil)
        // clear() IS called after page 1 success (2xx response clears the limiter).
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
    }

    // MARK: - No token returns nil immediately

    /// When no GitHub token is configured, `urlSessionAPIPaginated` returns nil
    /// without making any network request.
    ///
    /// - Note: This test temporarily sets the token provider to `{ nil }` on the
    ///   shared module-level `TransportBox`. It is safe only because
    ///   `@Suite(.serialized)` guarantees no other test in this suite runs
    ///   concurrently. Do not remove `.serialized` from the suite declaration.
    @Test func paginatedReturnsNilWhenNoToken() async {
        StubURLProtocol.reset()
        configureGHToken { nil }
        defer { configureGHToken { "test-token" } }

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)
        #expect(result == nil)
        // clear() must NOT be called — no-token returns without making a request.
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled == false)
    }

    // MARK: - Token revoked mid-pagination discards all items

    /// A token that is valid for page 1 but revoked before page 2 is requested
    /// must cause all partial items to be discarded and nil to be returned.
    ///
    /// Verifies: the `.noToken` arm in the pagination loop is reachable and
    /// correctly sets `didFailAuth = true` after page 1 has already been fetched.
    ///
    /// Mechanism: a lock-protected call counter is installed as the token provider.
    /// The first call to `githubTokenCore()` (page-1 iteration) returns "test-token";
    /// every subsequent call returns nil. Page 1 therefore succeeds and its item is
    /// accumulated. On the page-2 iteration, `urlSessionExecute` hits
    /// `guard let token = githubTokenCore()`, gets nil, and returns `.noToken`
    /// without making a network request. The pagination loop catches `.noToken`,
    /// sets `didFailAuth`, breaks, and returns nil — discarding the page-1 item.
    ///
    /// The page-2 URL is intentionally NOT registered in `StubURLProtocol`: if the
    /// token guard is ever accidentally removed, the stub miss produces a
    /// `fileDoesNotExist` URLError rather than silently serving data, making the
    /// regression immediately visible.
    ///
    /// Assertions:
    /// - `result == nil` — partial items are discarded on auth failure
    /// - `spy.setCalled == false` — `.noToken` is not a rate-limit event
    ///
    /// - Note: Safe under `@Suite(.serialized)` — the token mutation is sequenced
    ///   away from all other tests in this suite.
    ///
    /// - Warning: The call-count provider assumes `urlSessionExecute` calls
    ///   `githubTokenCore()` exactly once per pagination iteration (the
    ///   `guard let token = githubTokenCore()` at the top of the function).
    ///   If that guard is hoisted, cached, or called more than once per iteration,
    ///   the counter will misfire — either returning nil too early (page-1 gets
    ///   nil, test passes trivially) or too late (page-2 still gets a token,
    ///   stub miss produces a network error instead of `.noToken`). Re-examine
    ///   this test whenever `urlSessionExecute`'s token-read pattern changes.
    @Test func paginatedReturnsNilWhenTokenRevokedMidPagination() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

        // Page 1 succeeds and advertises a next page.
        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        // Page 2 is deliberately NOT registered — see method doc above.

        // Call-count–based token provider: returns a valid token for the first
        // githubTokenCore() read (page-1 iteration) and nil for all subsequent
        // reads (page-2 iteration onward). The lock makes the counter safe under
        // @Suite(.serialized) without requiring an actor hop.
        final class TokenCallCounter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> String? {
                lock.withLock {
                    defer { count += 1 }
                    return count == 0 ? "test-token" : nil
                }
            }
        }
        let counter = TokenCallCounter()
        configureGHToken { counter.next() }
        defer { configureGHToken { "test-token" } }

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Partial item from page 1 must be discarded — nil returned.
        #expect(result == nil)
        // The rate-limit actor must NOT have been armed — this is an auth failure,
        // not a rate-limit event.
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled == false)
        // clear() IS called after page 1 success (2xx response clears the limiter).
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
    }

    // MARK: - Pre-armed rate limit does not block first request

    /// A pre-armed rate-limit state (`spy.isLimited = true` before the call) does
    /// NOT block the initial request — the rate-limit check only fires inside
    /// `urlSessionExecute` after receiving a 403/429 response. Since page 1
    /// returns 200, clear() fires after the 2xx and resets isLimited to false.
    ///
    /// Verifies: the pre-armed state is not checked at call-entry, so page-1 items
    /// are returned and `spy.setCalled` remains false (no rate-limit response was
    /// received to trigger `handleRateLimitResponse`).
    @Test func paginatedReturnsItemsWhenPreArmedRateLimit() async {
        StubURLProtocol.reset()
        let pageURL = "\(apiBase)orgs/test/actions/runners"

        StubURLProtocol.register(.init(
            data: jsonPage([["id": "1", "name": "runner-a"]]),
            statusCode: 200,
            headers: [:]
        ), for: pageURL)

        let spy = SpyRateLimitActor()
        await spy.setUp(isLimited: true)

        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Page 1 must still be fetched — pre-armed state does not block the request.
        let items = decodeItems(result)
        #expect(items?.count == 1)
        #expect(items?[0]["id"] == .string("1"))
        // set() must NOT have been called — no rate-limit response was received.
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled == false)
        // clear() IS called after page 1 success (2xx response clears the limiter).
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
        // isLimited is reset by clear() after page 1 success.
        let snap = await spy.snapshot()
        #expect(snap.isLimited == false)
    }

    // MARK: - Non-auth HTTP error (404) returns partial results

    /// A 404 mid-pagination must stop pagination and return items collected from
    /// earlier pages — not nil. This verifies the `case .httpError: break pagination`
    /// path does NOT set `didFailAuth`, preserving partial results.
    @Test func paginatedReturnsPartialResultsOnHttpError404() async {
        StubURLProtocol.reset()
        let page1URL = "\(apiBase)orgs/test/actions/runners"
        let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
        let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

        StubURLProtocol.register(.init(
            data: page1Data,
            statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]
        ), for: page1URL)
        // 404 on page 2 — non-auth HTTP error.
        StubURLProtocol.register(.init(
            data: "{\"message\":\"Not found\"}".data(using: .utf8)!,
            statusCode: 404,
            headers: [:]
        ), for: page2URL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // Partial results from page 1 must be returned — not nil.
        #expect(result != nil)
        let items = decodeItems(result)
        #expect(items?.count == 1)
        #expect(items?[0]["id"] == .string("1"))
        // clear() IS called after page 1 success (2xx response clears the limiter).
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled)
        // set() must NOT be called — 404 is not a rate-limit event.
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled == false)
    }

    // MARK: - Non-auth HTTP error on the very first page returns nil

    /// A non-auth HTTP error (e.g. 404) on the very first page — before any items
    /// are accumulated — must return nil.
    ///
    /// Verifies: `case .httpError: break pagination` exits the loop with
    /// `hadAtLeastOneSuccessfulPage == false`, so the post-loop guard fails and
    /// nil is returned. This distinguishes the first-page error from the partial-
    /// results path tested by `paginatedReturnsPartialResultsOnHttpError404`.
    @Test func paginatedReturnsNilOnHttpErrorFirstPage() async {
        StubURLProtocol.reset()
        let pageURL = "\(apiBase)orgs/test/actions/runners"

        // 404 on the very first page — no prior items accumulated.
        StubURLProtocol.register(.init(
            data: "{\"message\":\"Not found\"}".data(using: .utf8)!,
            statusCode: 404,
            headers: [:]
        ), for: pageURL)

        let spy = SpyRateLimitActor()
        let result = await urlSessionAPIPaginated("/orgs/test/actions/runners", rateLimiter: spy)

        // No items were ever collected — nil must be returned.
        #expect(result == nil)
        // Neither set() nor clear() should be called — 404 is not a rate-limit event
        // and no 2xx page succeeded.
        let wasSetCalled = await spy.setCalled
        #expect(wasSetCalled == false)
        let wasClearCalled = await spy.clearCalled
        #expect(wasClearCalled == false)
    }
}
