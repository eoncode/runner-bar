// GitHubTransportShim.swift
// RunnerBarCore
//
// Provides module-level `ghAPI`, `ghRaw` symbols
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

/// A sync closure that returns the active GitHub personal access token, or `nil` if
/// no token is currently available. Used by `GitHubURLSessionTransport` inside
/// `RunnerBarCore` so the transport layer stays independent of the app target's
/// `Keychain` / `OAuthService` implementations.
public typealias GHTokenProvider = @Sendable () -> String?

// MARK: - TransportBox

/// Thread-safe wrapper around an `OSAllocatedUnfairLock`-guarded closure.
///
/// Collapses the repeated configure/read lock pair that each transport type
/// previously declared independently. `configure(_:)` replaces the stored
/// value under the lock; `read()` reads it under the lock so the caller can
/// invoke the closure outside (important for async closures — `withLock`
/// cannot contain an `await`).
private struct TransportBox<T: Sendable> {
    /// The underlying unfair lock protecting the stored value.
    private let lock: OSAllocatedUnfairLock<T>
    /// Creates a box with the given initial value.
    init(initialState: T) { lock = .init(initialState: initialState) }
    /// Replaces the stored value under the lock.
    func configure(_ value: T) { lock.withLock { $0 = value } }
    /// Returns the stored value under the lock.
    func read() -> T { lock.withLock { $0 } }
}

// MARK: - Module-level state

/// Serialises all reads and writes to the active JSON transport closure.
private let transportBox = TransportBox<GHAPITransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active raw-bytes transport closure.
private let rawTransportBox = TransportBox<GHRawTransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active token-provider closure.
private let tokenProviderBox = TransportBox<GHTokenProvider>(initialState: { nil })

// MARK: - Configuration

/// Wire up the real (or mock) GitHub JSON transport. Call once at launch before any fetch.
///
/// - Parameter transport: Async closure for JSON REST calls; returns `nil` on failure.
public func configureGHAPI(
    _ transport: @escaping GHAPITransport
) {
    transportBox.configure(transport)
}

/// Wire up the raw-bytes transport for log endpoints. Call once at launch.
///
/// - Parameter rawTransport: Async closure that fetches raw log bytes;
///   follows 302 redirects and returns `nil` on failure.
public func configureGHRaw(_ rawTransport: @escaping GHRawTransport) {
    rawTransportBox.configure(rawTransport)
}

/// Wire up the token provider. Call once at launch before any authenticated fetch.
///
/// - Parameter provider: Sync closure that returns the current GitHub token, or `nil`
///   when no token is available (e.g. user is signed out).
public func configureGHToken(_ provider: @escaping GHTokenProvider) {
    tokenProviderBox.configure(provider)
}

// MARK: - Module-level symbols consumed by RunnerBarCore files

/// Calls the configured GitHub API transport for the given endpoint.
/// Reads the closure under the lock then awaits it outside —
/// `OSAllocatedUnfairLock.withLock` cannot contain an `await`.
func ghAPI(_ endpoint: String) async -> Data? {
    let transport = transportBox.read()
    return await transport(endpoint)
}

/// Calls the configured raw-bytes transport for the given endpoint.
/// Used by `LogFetcher` to fetch log data without importing the app target.
/// Reads the closure under the lock then awaits it outside —
/// `OSAllocatedUnfairLock.withLock` cannot contain an `await`.
func ghRaw(_ endpoint: String) async -> Data? {
    let transport = rawTransportBox.read()
    return await transport(endpoint)
}

/// Returns the active GitHub token via the configured provider.
/// Reads the closure under the lock then invokes it outside —
/// `OSAllocatedUnfairLock.withLock` cannot contain a non-trivial call.
func githubTokenCore() -> String? {
    let provider = tokenProviderBox.read()
    return provider()
}
