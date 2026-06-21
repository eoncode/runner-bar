// GitHubTransportPaginatedTests.swift
// RunnerBarCoreTests
//
// Integration tests for urlSessionAPIPaginated.
// Uses URLProtocol stubbing + configureGHToken + SpyRateLimitActor to exercise
// the real pagination loop, rate-limit partial-return, and auth-abort logic.
//
// @Suite(.serialized) is required: paginatedReturnsNilWhenNoToken mutates the
// shared module-level token provider, and each test calls StubURLProtocol.reset()
// on the shared stub registry. Swift Testing runs struct suites concurrently by
// default; without serialization these two pieces of shared global state race.
//
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - StubURLProtocol

/// A URLProtocol subclass that serves pre-registered per-URL responses.
/// Register stubs before each test; the registry is cleared in teardown.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// A single canned response for one URL.
    struct Stub {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
    }

    // `nonisolated(unsafe)` — both properties are manually protected by `lock`
    // below; Swift 6 strict concurrency requires the annotation for static stored
    // properties on Sendable types that are not actor-isolated.
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

    static func register(_ stub: Stub, for url: String) {
        lock.withLock { stubs[url] = stub }
    }

    static func reset() {
        lock.withLock { stubs = [:] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        let key = request.url?.absoluteString ?? ""
        return lock.withLock { stubs[key] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
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

/// Base URL used by all stubs (must match GitHubConstants.apiBase resolution).
private let apiBase = "https://api.github.com/"

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
@Suite("GitHubTransportPaginated", .serialized)
struct GitHubTransportPaginatedTests {

    init() {
        // Register stub protocol and a valid token before every test.
        URLProtocol.registerClass(StubURLProtocol.self)
        configureGHToken { "test-token" }
    }

    // Teardown via deinit is not available on structs; stubs are reset at the
    // top of each test to keep tests independent.

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

    // MARK: - Rate-limit partial return

    /// A genuine 429 rate-limit mid-pagination arms the spy and returns partial items.
    ///
    /// Verifies: `.rateLimited` path returns collected items (not nil), and
    /// `SpyRateLimitActor.setCalled` is true — confirming the injected actor
    /// (not the global) was armed.
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
        // 429 on page 2 — genuine rate limit (always a rate limit by definition).
        StubURLProtocol.register(.init(
            data: Data(),
            statusCode: 429,
            headers: ["X-RateLimit-Remaining": "0"]
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
    }

    // MARK: - 401 auth failure discards all items

    /// A 401 mid-pagination must discard all partially collected items and return nil.
    ///
    /// Verifies: `.httpError(401)` triggers `didFailAuthentication`, and the
    /// auth-abort semantics introduced in the #1476 refactor are preserved.
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
    }
}
