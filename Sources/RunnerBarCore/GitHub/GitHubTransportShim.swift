// GitHubTransportShim.swift
// RunnerBarCore
//
// Provides module-level `ghAPI`, `ghRawTransport`, and `ghIsRateLimited` symbols
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

/// A synchronous raw-bytes fetch for GitHub log endpoints.
/// These endpoints 302-redirect to S3; the transport must follow redirects.
public typealias GHRawTransport = @Sendable (_ endpoint: String) -> Data?

// MARK: - Module-level state

/// The active JSON transport closure.
/// Serialises all reads and writes to the active transport closure.
private let transportLock = OSAllocatedUnfairLock<GHAPITransport>(initialState: { _ in nil })

/// The active raw-bytes transport closure (log endpoints).
/// Serialises all reads and writes to the active raw transport closure.
private let rawTransportLock = OSAllocatedUnfairLock<GHRawTransport>(initialState: { _ in nil })

/// Closure that reports the current rate-limit state.
/// Serialises all reads and writes to the rate-limit closure.
private let rateLimitLock = OSAllocatedUnfairLock<@Sendable () -> Bool>(initialState: { false })

// MARK: - Configuration

/// Wire up the real (or mock) GitHub transports. Call once at launch before any fetch.
///
/// - Parameters:
///   - transport: Async closure for JSON REST calls; returns `nil` on failure.
///   - isRateLimited: Returns `true` when the API is rate-limited.
public func configureGHAPI(
    _ transport: @escaping GHAPITransport,
    isRateLimited: @escaping @Sendable () -> Bool
) {
    transportLock.withLock { $0 = transport }
    rateLimitLock.withLock { $0 = isRateLimited }
}

/// Wire up the raw-bytes transport for log endpoints. Call once at launch.
///
/// - Parameter rawTransport: Synchronous closure that fetches raw log bytes;
///   follows 302 redirects and returns `nil` on failure.
public func configureGHRaw(_ rawTransport: @escaping GHRawTransport) {
    rawTransportLock.withLock { $0 = rawTransport }
}

// MARK: - Module-level symbols consumed by RunnerBarCore files

/// Calls the configured GitHub API transport for the given endpoint.
/// Reads the closure under the lock then awaits it outside —
/// `OSAllocatedUnfairLock.withLock` cannot contain an `await`.
func ghAPI(_ endpoint: String) async -> Data? {
    let transport = transportLock.withLock { $0 }
    return await transport(endpoint)
}

/// Returns the configured raw-bytes transport closure.
/// Used by `LogFetcher` to fetch log data without importing the app target.
/// - Note: Returns the closure itself, not the result of a call — callers invoke it directly.
func ghRawTransport() -> GHRawTransport {
    rawTransportLock.withLock { $0 }
}

/// Returns `true` when the GitHub API is currently rate-limiting this client.
var ghIsRateLimited: Bool {
    rateLimitLock.withLock { $0() }
}
