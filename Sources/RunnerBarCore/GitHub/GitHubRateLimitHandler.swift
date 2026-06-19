// GitHubRateLimitHandler.swift
// RunnerBarCore

import Foundation

// MARK: - RateLimitActor

/// Actor-isolated rate-limit state.
///
/// Replaces the old `RateLimitState` struct + `OSAllocatedUnfairLock` + `DispatchWorkItem`
/// pattern. The actor serialises all reads and writes; the reset timer uses a structured
/// `Task` + `Task.sleep(for:)` instead of `DispatchQueue.global().asyncAfter`, so it is
/// natively cancellable and requires no `@unchecked Sendable` escape hatch.
///
/// Pipeline:
///   1. `urlSessionAPIAsync` / `urlSessionAPIPaginated` receive a 403/429.
///   2. They call `rateLimitActor.set(resetAt:)` to arm the rate-limit flag and
///      schedule an automatic clear after the window.
///   3. `ghIsRateLimited` (Bool) and `ghRateLimitSnapshot()` (isLimited + resetDate)
///      expose the current values as `async` accessors backed by the actor.
///   4. `RunnerStore.applyFetchResult` copies both into its own `@MainActor`
///      properties (`isRateLimited`, `rateLimitResetDate`) via a single atomic
///      `snapshot()` call, eliminating the race window between two separate awaits.
///   5. `RunnerViewModel.reload()` mirrors them into `@Published` props.
///   6. `PanelMainView.rateLimitBanner` renders a live countdown using
///      `store.rateLimitResetDate` + the existing 1-second `displayTick`.
public actor RateLimitActor {
    /// Whether the GitHub API is currently rate-limiting this client.
    public private(set) var isLimited = false
    /// The moment at which the rate-limit window expires.
    /// Derived from the clamped delay (not the raw server timestamp) so that the
    /// UI countdown and the internal auto-clear timer always agree.
    /// `nil` when the reset time is unknown.
    public private(set) var resetDate: Date?
    /// Structured task that clears `isLimited` when it fires.
    private var resetTask: Task<Void, Never>?
    /// Incremented on every `set(resetAt:)` call. Captured by each reset task
    /// and compared in `didFire` to ensure a stale task from a cancelled window
    /// cannot clear state that belongs to a newer rate-limit window.
    private var generation = 0

    /// Creates a new `RateLimitActor` instance.
    public init() {}

    /// Arms the rate-limit flag and schedules an automatic reset.
    ///
    /// - Parameter resetAt: Unix timestamp from the `X-RateLimit-Reset` response header.
    ///   When non-nil the reset fires precisely at that time (clamped to [5, 7200] s);
    ///   otherwise falls back to 60 minutes from now.
    public func set(resetAt: TimeInterval?) {
        let delay: TimeInterval
        if let ts = resetAt {
            let secondsUntilReset = ts - Date().timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
        } else {
            delay = 3600
        }
        let date = Date().addingTimeInterval(delay)
        log("RateLimitActor › arming: delay=\(Int(delay))s resetDate=\(date)")
        generation &+= 1
        let capturedGeneration = generation
        resetTask?.cancel()
        isLimited = true
        resetDate = date
        resetTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self.didFire(generation: capturedGeneration, scheduledDelay: delay)
        }
    }

    /// Clears the rate-limit flag and cancels any pending reset task.
    public func clear() {
        resetTask?.cancel()
        resetTask = nil
        isLimited = false
        resetDate = nil
    }

    /// Returns both `isLimited` and `resetDate` in a single actor hop, guaranteeing consistency.
    public func snapshot() -> (isLimited: Bool, resetDate: Date?) {
        (isLimited: isLimited, resetDate: resetDate)
    }

    // MARK: Private

    private func didFire(generation: Int, scheduledDelay: TimeInterval) {
        guard generation == self.generation else {
            log("RateLimitActor › stale didFire ignored (gen=\(generation) current=\(self.generation))")
            return
        }
        isLimited = false
        resetDate = nil
        resetTask = nil
        log("RateLimitActor › auto-reset fired after \(Int(scheduledDelay))s")
    }
}

/// The module-wide `RateLimitActor` instance shared by `GitHubResponseDecoder`
/// and `GitHubURLSessionTransport`.
public let rateLimitActor = RateLimitActor()

// MARK: - Rate-limit accessors

/// Whether the GitHub API is currently rate-limiting this client.
/// Backed by `RateLimitActor`; must be `await`-ed from async contexts.
///
/// This is a computed async property — SE-0461 executor annotations (`@concurrent`,
/// `nonisolated(nonsending)`) apply to `func` declarations, not `var get async`.
/// As a nonisolated computed async var, it inherits the caller's executor, which is
/// equivalent to `nonisolated(nonsending)` on a func.
///
/// - Note: If you need both `isLimited` and `resetDate` in the same call, prefer
///   `ghRateLimitSnapshot()` to avoid the TOCTOU window between two separate actor hops.
public var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

/// Clears the rate-limit flag. Called at the start of each poll cycle in `RunnerStore.fetch()`.
///
/// Uses `nonisolated(nonsending)` rather than `@concurrent`: this function has no work
/// before its first suspension, so caller-context inheritance is always correct.
/// A `@concurrent` annotation would add a redundant hop to the cooperative thread pool
/// before the function immediately suspends onto `rateLimitActor`'s executor.
/// `@MainActor` callers release the main thread at the first `await`, so there is no
/// risk of main-thread blocking even without a prior cooperative-pool hop.
nonisolated(nonsending)
public func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

/// Returns `isLimited` and `resetDate` in a single actor hop.
///
/// Prefer this over reading `ghIsRateLimited` and `rateLimitActor.resetDate` separately:
/// two individual reads involve two actor hops with a TOCTOU window between them.
///
/// Uses `nonisolated(nonsending)` rather than `@concurrent`: this function has no work
/// before its first suspension, so caller-context inheritance is always correct.
/// A `@concurrent` annotation would add a redundant hop to the cooperative thread pool
/// before the function immediately suspends onto `rateLimitActor`'s executor.
/// `@MainActor` callers release the main thread at the first `await`, so there is no
/// risk of main-thread blocking even without a prior cooperative-pool hop.
nonisolated(nonsending)
public func ghRateLimitSnapshot() async -> (isLimited: Bool, resetDate: Date?) {
    await rateLimitActor.snapshot()
}
