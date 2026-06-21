// GitHubTransportShim.swift
// RunnerBarCore
//
// Provides module-level `ghAPI`, `ghRaw`, `ghAPIPaginated` symbols
// for RunnerBarCore consumers (WorkflowActionGroupFetch, RunnerStatusEnricher,
// LogFetcher).
//
// These are thin forwarding stubs backed by configurable transport closures so
// that:
//   • RunnerBarCore stays independent of the RunnerBar app target.
//   • Tests can inject a mock transport without touching URLSession.
//   • The app target wires the real GitHubURLSessionTransport at launch.
//
import Foundation
import os

// MARK: - Transport types

/// An async GitHub API fetch returning raw JSON `Data`.
/// Used for standard REST GET endpoints.
public typealias GHAPITransport = @Sendable (_ endpoint: String) async -> Data?

/// An async raw-bytes fetch for GitHub log endpoints.
/// These endpoints 302-redirect to S3; the transport must follow redirects.
public typealias GHRawTransport = @Sendable (_ endpoint: String) async -> Data?

/// An async paginated GitHub API fetch returning concatenated JSON array `Data`.
/// Used for list endpoints that follow `Link: rel="next"` pagination.
/// Returns `nil` on auth failure; may return partial results on rate-limit.
///
/// - Parameters:
///   - endpoint: Relative or absolute URL for the first page.
///   - timeout: Per-request timeout forwarded to `URLSession`.
public typealias GHAPIPaginatedTransport = @Sendable (_ endpoint: String, _ timeout: TimeInterval) async -> Data?

/// A sync closure that returns the active GitHub personal access token, or `nil`.
public typealias GHTokenProvider = @Sendable () -> String?

// MARK: - TransportBox

/// Thread-safe wrapper around an `OSAllocatedUnfairLock`-guarded closure.
private struct TransportBox<T: Sendable> {
    /// The underlying unfair lock guarding the stored value.
    private let lock: OSAllocatedUnfairLock<T>
    /// Creates a box with `initialState` as the starting value.
    init(initialState: T) { lock = .init(initialState: initialState) }
    /// Replaces the stored value under the lock.
    func configure(_ value: T) {
        lock.withLock { $0 = value }
    }
    /// Returns the stored value under the lock.
    func read() -> T { lock.withLock { $0 } }
}

// MARK: - Module-level state

/// Serialises all reads and writes to the active JSON transport closure.
private let transportBox = TransportBox<GHAPITransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active raw-bytes transport closure.
private let rawTransportBox = TransportBox<GHRawTransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active paginated JSON transport closure.
private let paginatedTransportBox = TransportBox<GHAPIPaginatedTransport>(initialState: { _, _ in nil })

/// Serialises all reads and writes to the active token-provider closure.
private let tokenProviderBox = TransportBox<GHTokenProvider>(initialState: { nil })

// MARK: - Configuration

/// Wire up the real (or mock) GitHub JSON transport. Call once at launch.
/// - Parameter transport: Async closure for JSON REST calls; returns `nil` on failure.
public func configureGHAPI(
    _ transport: @escaping GHAPITransport
) {
    transportBox.configure(transport)
}

/// Wire up the raw-bytes transport for log endpoints. Call once at launch.
/// - Parameter rawTransport: Async closure that fetches raw log bytes.
public func configureGHRaw(_ rawTransport: @escaping GHRawTransport) {
    rawTransportBox.configure(rawTransport)
}

/// Wire up the real (or mock) paginated JSON transport. Call once at launch.
/// - Parameter transport: Async closure for paginated REST calls.
public func configureGHAPIPaginated(_ transport: @escaping GHAPIPaginatedTransport) {
    paginatedTransportBox.configure(transport)
}

/// Wire up the token provider. Call once at launch.
/// - Parameter provider: Sync closure returning the current GitHub token.
public func configureGHToken(_ provider: @escaping GHTokenProvider) {
    tokenProviderBox.configure(provider)
}

// MARK: - Module-level symbols consumed by RunnerBarCore files

/// Calls the configured GitHub API transport for the given endpoint.
///
/// Increments `apiCallCounter` via a fire-and-forget `Task` before dispatching
/// so the counter reflects every REST call without adding latency to the fetch.
func ghAPI(_ endpoint: String) async -> Data? {
    _ = Task { await apiCallCounter.record() }
    let transport = transportBox.read()
    return await transport(endpoint)
}

/// Calls the configured raw-bytes transport for the given endpoint.
///
/// Raw log fetches hit S3 and do **not** consume the GitHub REST quota —
/// `apiCallCounter` is intentionally not incremented here.
func ghRaw(_ endpoint: String) async -> Data? {
    let transport = rawTransportBox.read()
    return await transport(endpoint)
}

/// Calls the configured paginated JSON transport for the given endpoint.
///
/// Increments `apiCallCounter` via a fire-and-forget `Task` — paginated
/// calls consume the same GitHub REST quota as single-page calls.
///
/// - Parameters:
///   - endpoint: Relative or absolute URL for the first page.
///   - timeout: Per-request timeout forwarded to the transport. Defaults to 60s.
@concurrent
public func ghAPIPaginated(_ endpoint: String, timeout: TimeInterval = 60) async -> Data? {
    _ = Task { await apiCallCounter.record() }
    let transport = paginatedTransportBox.read()
    return await transport(endpoint, timeout)
}

/// Returns the active GitHub token via the configured provider.
func githubTokenCore() -> String? {
    let provider = tokenProviderBox.read()
    return provider()
}
