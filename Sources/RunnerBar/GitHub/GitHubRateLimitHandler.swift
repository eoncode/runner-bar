// GitHubRateLimitHandler.swift
// RunnerBar

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
///   3. `ghIsRateLimited` / `ghRateLimitResetDate` expose the current values
///      as `async` computed properties backed by the actor.
///   4. `RunnerStore.applyFetchResult` copies both into its own `@MainActor`
///      properties (`isRateLimited`, `rateLimitResetDate`) via a single atomic
///      `snapshot()` call, eliminating the race window between two separate awaits.
///   5. `RunnerViewModel.reload()` mirrors them into `@Published` props.
///   6. `PanelMainView.rateLimitBanner` renders a live countdown using
///      `store.rateLimitResetDate` + the existing 1-second `displayTick`.
actor RateLimitActor {
    /// Whether the GitHub API is currently rate-limiting this client.
    private(set) var isLimited = false
    /// The moment at which the rate-limit window expires (mirrors X-RateLimit-Reset).
    /// `nil` when the reset time is unknown.
    private(set) var resetDate: Date?
    /// Structured task that clears `isLimited` when it fires.
    private var resetTask: Task<Void, Never>?

    /// Arms the rate-limit flag and schedules an automatic reset.
    ///
    /// - Parameter resetAt: Unix timestamp from the `X-RateLimit-Reset` response header.
    ///   When non-nil the reset fires precisely at that time; otherwise falls back to
    ///   60 minutes from now.
    func set(resetAt: TimeInterval?) {
        let delay: TimeInterval
        let date: Date
        if let ts = resetAt {
            let secondsUntilReset = ts - Date().timeIntervalSince1970
            delay = min(max(secondsUntilReset, 5), 7200)
            date = Date(timeIntervalSince1970: ts)
        } else {
            delay = 3600
            date = Date().addingTimeInterval(delay)
        }
        log("ghIsRateLimited › auto-reset scheduled in \(Int(delay))s (resetDate=\(date))")
        resetTask?.cancel()
        isLimited = true
        resetDate = date
        resetTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self.didFire(scheduledDelay: delay)
        }
    }

    /// Clears the rate-limit flag and cancels any pending reset task.
    /// Unconditional — resets both `isLimited` and `resetDate` to keep them consistent.
    func clear() {
        resetTask?.cancel()
        resetTask = nil
        isLimited = false
        resetDate = nil
    }

    /// Returns both `isLimited` and `resetDate` in a single actor hop, guaranteeing consistency.
    func snapshot() -> (isLimited: Bool, resetDate: Date?) {
        (isLimited: isLimited, resetDate: resetDate)
    }

    // MARK: Private

    /// Fires when the `Task.sleep` in `set(resetAt:)` completes without cancellation.
    private func didFire(scheduledDelay: TimeInterval) {
        isLimited = false
        resetDate = nil
        resetTask = nil
        log("ghIsRateLimited › auto-reset fired after \(Int(scheduledDelay))s")
    }
}

/// The module-wide `RateLimitActor` instance shared by `GitHubResponseDecoder`
/// and `GitHubURLSessionTransport`. Internal so both files can call `set(resetAt:)`,
/// `clear()`, and `snapshot()` without duplication.
let rateLimitActor = RateLimitActor()

// MARK: - Rate-limit accessors

/// Whether the GitHub API is currently rate-limiting this client.
/// Backed by `RateLimitActor`; must be `await`-ed from async contexts.
var ghIsRateLimited: Bool {
    get async { await rateLimitActor.isLimited }
}

/// Clears the rate-limit flag. Called at the start of each poll cycle in `RunnerStore.fetch()`.
func clearGhRateLimit() async {
    await rateLimitActor.clear()
}

/// Returns `isLimited` and `resetDate` in a single actor hop.
/// Prefer this over separate `await ghIsRateLimited` + `await ghRateLimitResetDate` calls
/// to avoid the TOCTOU window between two hops.
func ghRateLimitSnapshot() async -> (isLimited: Bool, resetDate: Date?) {
    await rateLimitActor.snapshot()
}
