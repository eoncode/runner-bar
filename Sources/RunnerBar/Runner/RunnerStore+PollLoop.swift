// RunnerStore+PollLoop.swift
// RunnerBar
import Combine
import Foundation

// MARK: - Poll loop

/// Poll-loop management for `RunnerStore`.
extension RunnerStore {
    /// Starts (or restarts) the structured async poll loop.
    ///
    /// Cancels any existing poll task, then launches a new one that:
    ///   1. Fires an immediate fetch.
    ///   2. Waits for a dynamic interval (rate-limit / active-work aware).
    ///   3. Repeats until cancelled.
    ///
    /// Safe to call multiple times — the previous task is always cancelled first.
    func start() {
        let scopes = ScopeStore.shared.activeScopes
        log("RunnerStore › start — activeScopes=\(scopes)")
        if scopes.isEmpty {
            log("RunnerStore › ⚠️ start called but activeScopes is EMPTY — actions will not load")
        }
        let localCount = LocalRunnerStore.shared.runners.count
        log("RunnerStore › start — LocalRunnerStore.shared.runners.count=\(localCount) at start() time")
        if localCount == 0 {
            log("RunnerStore › ⚠️ start — localRunners=0 at start time; installPathMap will be empty on first fetch. refresh() should have been called before start().")
        }
        pollTask?.cancel()
        log("RunnerStore › start — previous pollTask cancelled, launching new task")
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.fetch()
            while !Task.isCancelled {
                let interval = self.nextPollInterval()
                log("RunnerStore › poll loop — next fetch in \(Int(interval))s")
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch is CancellationError {
                    log("RunnerStore › poll loop — CancellationError, exiting cleanly")
                    break
                } catch {
                    log("RunnerStore › poll loop — unexpected error \(error), exiting")
                    break
                }
                guard !Task.isCancelled else {
                    log("RunnerStore › poll loop — cancelled after sleep, exiting")
                    break
                }
                await self.fetch()
            }
            log("RunnerStore › poll loop — exited (cancelled)")
        }
    }

    /// Returns the next poll interval in seconds, based on current store state.
    func nextPollInterval() -> TimeInterval {
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions = actions.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, AppPreferencesStore.shared.pollingInterval)
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle)")
        return interval
    }
}
