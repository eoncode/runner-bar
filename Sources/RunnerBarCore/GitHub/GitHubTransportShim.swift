// GitHubTransportShim.swift
// RunnerBarCore
//
// Provides module-level `ghAPI` and `ghIsRateLimited` symbols for RunnerBarCore
// consumers (WorkflowActionGroupFetch, RunnerStatusEnricher).
//
// These are thin forwarding stubs backed by a configurable transport closure so
// that:
//   • RunnerBarCore stays independent of the RunnerBar app target.
//   • Tests can inject a mock transport without touching URLSession or the gh CLI.
//   • The app target wires the real GitHubURLSessionTransport at launch.
//
import Foundation
import os

// MARK: - Transport protocol

/// A synchronous GitHub API fetch that returns raw JSON `Data` for a given
/// REST endpoint path (no leading `https://api.github.com`).
/// Returns `nil` on network error, rate-limit, or missing auth token.
public typealias GHAPITransport = @Sendable (_ endpoint: String) -> Data?

// MARK: - Module-level state

/// The active transport closure.  Set by the app target once at launch via
/// `configureGHAPI(_:isRateLimited:)`.  Defaults to a no-op that always
/// returns `nil` so RunnerBarCore builds cleanly in unit-test targets that
/// don't wire up a real transport.
///
/// Safety: protected by transportLock.
private let transportLock = OSAllocatedUnfairLock<GHAPITransport>(initialState: { _ in nil })

/// Closure that reports the current rate-limit state.  Set alongside
/// `_transport` by `configureGHAPI(_:isRateLimited:)`.
/// Safety: protected by rateLimitLock.
private let rateLimitLock = OSAllocatedUnfairLock<@Sendable () -> Bool>(initialState: { false })

// MARK: - Configuration

/// Wire up the real (or mock) GitHub transport.  Call this once from the app
/// target's `AppDelegate` (or equivalent entry point) before any fetch begins.
///
/// - Parameters:
///   - transport: Synchronous closure that calls the GitHub REST API and
///     returns raw JSON data, or `nil` on failure / rate-limit.
///   - isRateLimited: Closure that returns `true` when the API is currently
///     rate-limited and calls should be skipped.
public func configureGHAPI(
    _ transport: @escaping GHAPITransport,
    isRateLimited: @escaping @Sendable () -> Bool
) {
    transportLock.withLock { $0 = transport }
    rateLimitLock.withLock { $0 = isRateLimited }
}

// MARK: - Module-level symbols consumed by RunnerBarCore files

/// Calls the configured GitHub API transport for the given endpoint.
///
/// Matches the signature of `ghAPI` in `GitHubURLSessionTransport.swift` so
/// that `WorkflowActionGroupFetch` and `RunnerStatusEnricher` compile without
/// modification.
func ghAPI(_ endpoint: String) -> Data? {
    transportLock.withLock { $0(endpoint) }
}

/// Returns `true` when the GitHub API is currently rate-limiting this client.
///
/// Matches the global `ghIsRateLimited` var in `GitHubURLSessionTransport.swift`.
var ghIsRateLimited: Bool {
    rateLimitLock.withLock { $0() }
}
