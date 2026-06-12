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

// MARK: - Module-level state

/// Serialises all reads and writes to the active JSON transport closure.
private let transportLock = OSAllocatedUnfairLock<GHAPITransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active raw-bytes transport closure.
private let rawTransportLock = OSAllocatedUnfairLock<GHRawTransport>(initialState: { _ in nil })

/// Serialises all reads and writes to the active token-provider closure.
private let tokenProviderLock = OSAllocatedUnfairLock<GHTokenProvider>(initialState: { nil })

// MARK: - Configuration

/// Wire up the real (or mock) GitHub JSON transport. Call once at launch before any fetch.
///
/// - Parameter transport: Async closure for JSON REST calls; returns `nil` on failure.
public func configureGHAPI(
    _ transport: @escaping GHAPITransport
) {
    transportLock.withLock { $0 = transport }
}

/// Wire up the raw-bytes transport for log endpoints. Call once at launch.
///
/// - Parameter rawTransport: Async closure that fetches raw log bytes;
///   follows 302 redirects and returns `nil` on failure.
public func configureGHRaw(_ rawTransport: @escaping GHRawTransport) {
    rawTransportLock.withLock { $0 = rawTransport }
}

/// Wire up the token provider. Call once at launch before any authenticated fetch.
///
/// - Parameter provider: Sync closure that returns the current GitHub token, or `nil`
///   when no token is available (e.g. user is signed out).
public func configureGHToken(_ provider: @escaping GHTokenProvider) {
    tokenProviderLock.withLock { $0 = provider }
}

// MARK: - Module-level symbols consumed by RunnerBarCore files

/// Calls the configured GitHub API transport for the given endpoint.
/// Reads the closure under the lock then awaits it outside —
/// `OSAllocatedUnfairLock.withLock` cannot contain an `await`.
func ghAPI(_ endpoint: String) async -> Data? {
    let transport = transportLock.withLock { $0 }
    return await transport(endpoint)
}

/// Calls the configured raw-bytes transport for the given endpoint.
/// Used by `LogFetcher` to fetch log data without importing the app target.
/// Reads the closure under the lock then awaits it outside —
/// `OSAllocatedUnfairLock.withLock` cannot contain an `await`.
func ghRaw(_ endpoint: String) async -> Data? {
    let transport = rawTransportLock.withLock { $0 }
    return await transport(endpoint)
}

/// Returns the active GitHub token via the configured provider.
/// Reads the closure under the lock then invokes it outside —
/// `OSAllocatedUnfairLock.withLock` cannot contain a non-trivial call.
func githubTokenCore() -> String? {
    tokenProviderLock.withLock { $0 }()
}
