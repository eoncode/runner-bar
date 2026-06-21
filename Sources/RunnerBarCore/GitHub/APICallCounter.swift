// APICallCounter.swift
// RunnerBarCore
//
// Tracks GitHub REST call timestamps in a rolling 60-minute window.
// Mirrors the RateLimitActor pattern (P16 — Actor-Per-Concern Isolation).
//
// Actor chosen over Mutex: record() performs an append + removeAll sweep on
// a [Date] array that can reach 5,000 entries under load — non-trivial work
// that must not block a cooperative thread pool worker under a lock.
// GitHubTokenCache uses Mutex for a single pointer swap (P13 reach goal);
// this case does not qualify because the critical section is not O(1).
import Foundation

// MARK: - APICallCounterSnapshot

/// Atomic snapshot of API call-counter state returned by `APICallCounterProtocol.snapshot()`.
///
/// Using a nominal struct rather than an anonymous tuple prevents conformers from
/// accidentally dropping named labels and keeps the return type extensible
/// (e.g. `Equatable`, `Codable`) without an API break.
/// Mirrors `RateLimitSnapshot` in `GitHubRateLimitHandler.swift`.
public struct APICallCounterSnapshot: Sendable, Equatable {
    /// Number of GitHub REST calls made in the last rolling 60-minute window.
    public let count: Int
    /// GitHub authenticated REST rate limit per rolling hour.
    public let limit: Int
    /// Fraction of the hourly limit consumed, clamped to `[0, 1]`.
    public var fraction: Double { min(Double(count) / Double(limit), 1.0) }

    /// Creates a new snapshot.
    ///
    /// - Parameters:
    ///   - count: Calls made in the last rolling 60 minutes.
    ///   - limit: GitHub hourly REST rate limit (typically 5,000).
    public init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
    }
}

// MARK: - APICallCounterProtocol

/// Injectable abstraction over `APICallCounter` for deterministic testing (P7).
///
/// `APICallCounterViewModel` accepts any conforming type via a defaulted
/// `counter` parameter so production code is unchanged while tests can
/// substitute a `SpyAPICallCounter` without touching the real actor.
public protocol APICallCounterProtocol: Actor {
    /// Record one GitHub REST API call.
    func record()
    /// Returns `count` and `limit` in a single actor hop (P10 — Atomic Snapshot Pattern).
    func snapshot() -> APICallCounterSnapshot
}

// MARK: - APICallCounter

/// Actor-isolated ring buffer of GitHub REST call timestamps.
///
/// `record()` is called once per `ghAPI()` / `ghAPIPaginated()` dispatch
/// via a fire-and-forget `Task` in `GitHubTransportShim`. `ghRaw()` is
/// intentionally excluded — raw log fetches hit S3 and do not consume
/// the GitHub REST quota.
///
/// No persistence — the counter resets on app launch by design.
/// Memory is bounded: `record()` purges entries older than 3,600 s on
/// every call, capping the array at `hourlyLimit` entries at most.
public actor APICallCounter: APICallCounterProtocol {
    /// Shared instance wired at module level, matching the `rateLimitActor` convention.
    public static let shared = APICallCounter()

    /// GitHub authenticated REST rate limit per rolling hour.
    /// Surfaced as a constant so it can be updated if GitHub changes it.
    public static let hourlyLimit = 5_000

    /// Rolling buffer of call timestamps.
    /// Purged on every `record()` to bound memory; never exceeds `hourlyLimit` entries.
    private var timestamps: [Date] = []

    /// Creates a new `APICallCounter` instance.
    public init() {}

    /// Records one GitHub REST API call.
    ///
    /// Appends the current timestamp and purges entries older than 60 minutes
    /// to keep the array bounded. Called via a fire-and-forget `Task` from
    /// `ghAPI()` and `ghAPIPaginated()` in `GitHubTransportShim`.
    public func record() {
        let now = Date()
        timestamps.append(now)
        let cutoff = now.addingTimeInterval(-3_600)
        timestamps.removeAll { $0 < cutoff }
    }

    /// Returns `count` and `limit` in a single actor hop, guaranteeing consistency (P10).
    ///
    /// Prefer this over reading count and limit separately to avoid a TOCTOU
    /// window between two independent actor hops.
    public func snapshot() -> APICallCounterSnapshot {
        let cutoff = Date().addingTimeInterval(-3_600)
        let count = timestamps.filter { $0 >= cutoff }.count
        return APICallCounterSnapshot(count: count, limit: Self.hourlyLimit)
    }
}

// MARK: - Module-level accessor

/// The module-wide `APICallCounter` instance shared by `GitHubTransportShim`.
/// Public so both `ghAPI()` and `ghAPIPaginated()` can call `record()` without
/// crossing module boundaries. Mirrors the `rateLimitActor` pattern.
public let apiCallCounter = APICallCounter.shared
