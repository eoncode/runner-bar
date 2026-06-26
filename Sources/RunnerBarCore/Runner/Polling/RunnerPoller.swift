// RunnerPoller.swift
// RunnerBarCore
//
// Step 10: RunnerStore renamed to RunnerPoller and moved into RunnerBarCore.
// Step 14: applyFetchResult writes only to RunnerState (no viewModel.* writes remain).
// App-layer dependencies replaced with protocol-typed injections and closures
// so Core has no import of the RunnerBar app target.

import Collections
import Foundation
import os

// MARK: - RunnerPoller

/// Swift 6 actor that owns the GitHub poll loop and all derived runner/job/action state.
///
/// **Concurrency model**
/// - The actor runs on its own executor (background thread).
/// - `preferencesStore` and `scopeStore` are `@MainActor`-isolated `Sendable` protocol
///   values; any read of their properties must happen inside `await MainActor.run { }`.
/// - After every fetch cycle, results are pushed to the injected `RunnerState` on the
///   main actor via `await MainActor.run { }`. SwiftUI's `@Observable` machinery
///   picks up the mutation automatically — no Combine `PassthroughSubject` needed.
/// - Local-runner state is read via the injected `localRunners` closure, which returns
///   a `@MainActor`-isolated snapshot without crossing into the app layer.
/// - Status-icon refresh is no longer triggered from inside the actor. `AppDelegate` wires
///   an `ObservationLoop` on `state.runners` in Step 13.
public actor RunnerPoller {

    // MARK: - State

    /// Runners currently shown in the panel.
    var runners: [Runner] = []
    /// Jobs currently shown in the panel, including dimmed completed entries.
    var jobs: [ActiveJob] = []
    /// Workflow action groups currently shown in the panel.
    var actions: [WorkflowActionGroup] = []
    /// Live-job snapshot from the previous poll, used to detect vanished jobs.
    var prevLiveJobs: [Int: ActiveJob] = [:]
    /// Completed-job cache keyed by job ID; capped at `PollResultBuilder.jobCacheLimit`.
    var completedCache: [Int: ActiveJob] = [:]
    /// Live-group snapshot from the previous poll, used to detect vanished groups.
    var prevLiveGroups: [String: WorkflowActionGroup] = [:]
    /// Group cache keyed by group ID; capped at `PollResultBuilder.groupCacheLimit`.
    var actionGroupCache: [String: WorkflowActionGroup] = [:]
    /// IDs of action groups whose failure hook has already fired.
    ///
    /// Kept separate from `actionGroupCache` so that cache eviction does not re-arm
    /// the hook for old completed groups still present in GitHub's last-completed feed.
    /// `OrderedSet` preserves insertion order so `trimSeenGroupIDs` evicts the
    /// oldest entries first (FIFO), rather than arbitrary ones as `Set` would.
    var seenGroupIDs: OrderedSet<String> = []
    /// Whether the GitHub API is currently rate-limiting this client.
    var isRateLimited = false
    /// The exact moment the current rate-limit window expires, or `nil` when no
    /// rate-limit is active or the reset time is unknown.
    /// Assigned in `applyFetchResult` and written to `state`. periphery:ignore
    var rateLimitResetDate: Date?
    /// Owns the three structured `Task` handles for the poll loop.
    let pollLoop = PollLoopCoordinator()
    /// Observable read model — the source of truth for all views and AppDelegate observers.
    public let state: RunnerState
    /// Returns the current local-runner snapshot on the `@MainActor`.
    /// Injected at init so the actor body never imports the app-layer `LocalRunnerStore`.
    let localRunners: @MainActor @Sendable () -> [RunnerModel]
    /// Writes metrics back into the local runner store.
    /// Injected at init to decouple Core from the app-layer `LocalRunnerStore` actor.
    let applyMetrics: @Sendable (_ metrics: RunnerMetrics?, _ runnerId: Int, _ name: String) async -> Void
    /// Fires a failure hook for a newly-failed workflow action group.
    /// Injected at init so Core never imports the app-layer `FailureHookRunner`.
    /// `internal` so that extension files (e.g. `RunnerPoller+PollBridge`) can call it.
    let fireFailureHook: @Sendable (_ group: WorkflowActionGroup, _ scope: String) async -> Void
    /// Injected preferences store. Provides `pollingInterval`.
    let preferencesStore: any AppPreferencesStoreProtocol
    /// Injected scope store. Provides `activeScopes`.
    /// `internal` (not `private`) so that extension files can read this property.
    internal let scopeStore: any ScopeStoreProtocol
    /// Shared `JSONDecoder` — reused across all decode calls in the actor.
    ///
    /// `withTaskGroup` child tasks in `fetchAndEnrichRunners` (Phase 1 and Phase 2) access
    /// `self.decoder` concurrently. This is safe because:
    /// - `JSONDecoder` is stateless after initialisation (no mutable configuration
    ///   happens inside the task group).
    /// - It is declared `@unchecked Sendable` in the SDK, explicitly authorising
    ///   concurrent reads.
    /// No local capture (`let d = decoder`) is required for correctness; `self.decoder`
    /// is equally safe. The property access touches the actor executor as a normal
    /// actor-isolated `let` read — it does not serialise the concurrent child tasks.
    let decoder = JSONDecoder()
    /// Fetcher for workflow action groups.
    let actionGroupFetcher: any WorkflowActionGroupFetcherProtocol

    // MARK: - Init

    /// Designated init for dependency injection.
    ///
    /// - Parameters:
    ///   - state: The observable read model that views and AppDelegate observe.
    ///   - preferencesStore: Provides `pollingInterval`.
    ///   - scopeStore: Provides `activeScopes`.
    ///   - localRunners: Closure returning the current local-runner snapshot on `@MainActor`.
    ///   - applyMetrics: Closure that writes enriched metrics back to the local runner store.
    ///   - fireFailureHook: Closure that fires a failure hook for a newly-failed action group.
    ///   - actionGroupFetcher: Fetcher for workflow action groups.
    public init(
        state: RunnerState,
        preferencesStore: any AppPreferencesStoreProtocol,
        scopeStore: any ScopeStoreProtocol,
        localRunners: @escaping @MainActor @Sendable () -> [RunnerModel],
        applyMetrics: @escaping @Sendable (_ metrics: RunnerMetrics?, _ runnerId: Int, _ name: String) async -> Void,
        fireFailureHook: @escaping @Sendable
            (_ group: WorkflowActionGroup, _ scope: String) async -> Void = { _, _ in },
        actionGroupFetcher: any WorkflowActionGroupFetcherProtocol = WorkflowActionGroupFetcher()
    ) {
        self.state = state
        self.preferencesStore = preferencesStore
        self.scopeStore = scopeStore
        self.localRunners = localRunners
        self.applyMetrics = applyMetrics
        self.fireFailureHook = fireFailureHook
        self.actionGroupFetcher = actionGroupFetcher
        Task(name: "RunnerPoller.init: startObservingPreferences") { await self.startObservingPreferences() }
        Task(name: "RunnerPoller.init: startObservingScopes") { await self.startObservingScopes() }
    }

    // MARK: - Deinit

    /// Cancels all running Tasks owned by this actor before it is freed.
    isolated deinit {
        pollLoop.cancelAll()
    }

    // MARK: - Poll loop

    /// Starts (or restarts) the structured async poll loop.
    public func start() async {
        let scopes = await MainActor.run { scopeStore.activeScopes }
        log("RunnerPoller › start — activeScopes=\(scopes)", category: .runner)
        if scopes.isEmpty {
            log("RunnerPoller › ⚠️ start called but activeScopes is EMPTY — actions will not load", category: .runner)
        }
        let localCount = await MainActor.run { localRunners().count }
        log("RunnerPoller › start — localRunners.count=\(localCount) at start() time", category: .runner)
        if localCount == 0 {
            log("RunnerPoller › ⚠️ start — localRunners=0 at start time; installPathMap will be empty on first fetch.", category: .runner)
        }
        log("RunnerPoller › start — previous pollTask cancelled, launching new poll task", category: .runner)
        pollLoop.setPollTask(Task { [weak self] in
            guard let self else { return }
            await self.fetch()
            while !Task.isCancelled {
                let interval = await self.nextPollInterval()
                log("RunnerPoller › poll loop — next fetch in \(Int(interval))s", category: .runner)
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch is CancellationError {
                    log("RunnerPoller › poll loop — CancellationError, exiting cleanly", category: .runner)
                    break
                } catch {
                    log("RunnerPoller › poll loop — unexpected error \(error), exiting", category: .runner)
                    break
                }
                guard !Task.isCancelled else {
                    log("RunnerPoller › poll loop — cancelled after sleep, exiting", category: .runner)
                    break
                }
                await self.fetch()
            }
        })
    }

    /// Computes the delay before the next poll.
    ///
    /// Uses typed `JobStatus` enum cases rather than raw string literals so that
    /// a raw-value rename is caught at compile time. `ActiveJob.status` and
    /// `WorkflowActionGroup.groupStatus` are both `JobStatus`.
    private func nextPollInterval() async -> TimeInterval {
        let hasActiveJobs = jobs.contains { $0.status == .inProgress || $0.status == .queued }
        let hasActiveActions = actions.contains { $0.groupStatus == .inProgress || $0.groupStatus == .queued }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, await MainActor.run { preferencesStore.pollingInterval })
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerPoller › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle)", category: .runner)
        return interval
    }

    // MARK: - Fetch

    /// Performs one full poll cycle.
    ///
    /// Wraps the fetch body in a `do/catch` so any unhandled error surfaces via
    /// `applyError` rather than silently crashing or swallowing the failure.
    /// Existing fetch helpers (`buildJobState`, `buildGroupState`, `fetchAndEnrichRunners`)
    /// do not currently throw — they return empty arrays on failure. The `do/catch`
    /// guards against future changes that introduce throwing paths.
    ///
    /// Not on `RunnerPollerProtocol`. Use `start()` to drive the poll cadence.
    /// Accessible at `internal` scope so tests holding a concrete `RunnerPoller` can
    /// trigger a single cycle without going through the protocol seam.
    func fetch() async {
        do {
            try await fetchInternal()
        } catch {
            log("RunnerPoller › fetch — ⚠️ unhandled error: \(error)", category: .runner)
            await applyError(FetchError(error))
        }
    }

    /// Inner throwing fetch body. Extracted so `fetch()` can wrap it cleanly in `do/catch`.
    private func fetchInternal() async throws {
        await clearGhRateLimit()
        let scopesSnapshot = await MainActor.run { scopeStore.activeScopes }
        log("RunnerPoller › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)", category: .runner)
        if scopesSnapshot.isEmpty {
            log("RunnerPoller › ⚠️ fetch — activeScopes snapshot is EMPTY", category: .runner)
        }
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache
        let snapSeenGroupIDs = seenGroupIDs
        let localRunnersSnapshot = await MainActor.run { localRunners() }
        log("RunnerPoller › fetch — localRunners.count=\(localRunnersSnapshot.count) (used for installPathMap)", category: .runner)
        if localRunnersSnapshot.isEmpty {
            log("RunnerPoller › ⚠️ fetch — localRunners is EMPTY; installPathMap will be empty", category: .runner)
        } else {
#if DEBUG
            // swiftlint:disable:next line_length
            log("RunnerPoller › fetch — localRunners=\(localRunnersSnapshot.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })", category: .runner)
#endif
        }
        let installPathMap = buildInstallPathMap(
            scopes: scopesSnapshot,
            localRunners: localRunnersSnapshot
        )
        let enrichedRunners = await fetchAndEnrichRunners(
            scopes: scopesSnapshot,
            localRunners: localRunnersSnapshot,
            installPathMap: installPathMap
        )
        let jobResult = await buildJobState(snapPrev: snapPrev, snapCache: snapCache)
        let groupResult = await buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            snapSeenGroupIDs: snapSeenGroupIDs,
            jobCache: jobResult.newCache
        )
        await applyFetchResult(
            enrichedRunners: enrichedRunners,
            jobResult: jobResult,
            groupResult: groupResult
        )
    }

    /// Fetches all active jobs across all scopes.
    ///
    /// Iterates the active scopes, fetches workflow action groups for each scope,
    /// and returns the flattened job list from all groups. This gives the full
    /// set of live + recently-completed jobs for `PollResultBuilder.buildJobState`
    /// to split into live vs. cached display tiers.
    ///
    /// Passes `cache: [:]` intentionally — the job-polling path does not use the
    /// SHA-keyed deduplication that `buildGroupState` relies on. Each job poll
    /// fetches fresh group data so that no stale SHA entries suppress a live update.
    ///
    /// `internal` — called only via the `fetchJobs` closure passed to
    /// `PollResultBuilder.buildJobState`.
    func fetchAllJobs() async -> [ActiveJob] {
        let scopes = await MainActor.run { scopeStore.activeScopes }
        guard !scopes.isEmpty else { return [] }
        var allJobs: [ActiveJob] = []
        for scope in scopes {
            let groups = await actionGroupFetcher.fetch(for: scope, cache: [:])
            for group in groups {
                allJobs.append(contentsOf: group.jobs)
            }
        }
        log("RunnerPoller › fetchAllJobs — fetched \(allJobs.count) job(s) across \(scopes.count) scope(s)", category: .runner)
        return allJobs
    }

    /// Fetches workflow action groups for all active scopes, using the SHA-keyed cache.
    ///
    /// Iterates the active scopes and calls `actionGroupFetcher.fetch(for:cache:)`
    /// for each, merging results into a single flat array. The `shaKeyedCache`
    /// parameter is passed through to avoid refetching groups whose SHAs have
    /// already been fetched in the previous poll cycle.
    ///
    /// `internal` — called only via the `fetchGroups` closure passed to
    /// `PollResultBuilder.buildGroupState`.
    func fetchActionGroups(shaKeyedCache: [String: WorkflowActionGroup]) async -> [WorkflowActionGroup] {
        let scopes = await MainActor.run { scopeStore.activeScopes }
        guard !scopes.isEmpty else { return [] }
        var allGroups: [WorkflowActionGroup] = []
        for scope in scopes {
            let groups = await actionGroupFetcher.fetch(for: scope, cache: shaKeyedCache)
            allGroups.append(contentsOf: groups)
        }
        log("RunnerPoller › fetchActionGroups — fetched \(allGroups.count) group(s) across \(scopes.count) scope(s)", category: .runner)
        return allGroups
    }

    /// Backfills step data into the completed-job cache.
    ///
    /// Iterates jobs in `cache` that have a conclusion but missing or in-progress steps,
    /// fetches the full job payload from the GitHub API, and updates the cache entry.
    ///
    /// Uses `JobPayload` + `makeActiveJob(from:iso:isDimmed:)` — the same decoding path
    /// used everywhere else in the codebase — because `ActiveJob` has no `Decodable`
    /// conformance: dates are raw strings in the API response and must be parsed via
    /// `ISO8601DateParser.shared.formatter`. Decoding directly to `ActiveJob` would
    /// silently fail (the `try?` guard would always `continue`) and no steps would
    /// ever be backfilled.
    ///
    /// `scope` is preserved from the existing cache entry because scope is a local
    /// concept injected post-fetch — it is never present in the GitHub API job payload.
    /// Jobs whose cached `scope` is `nil` are skipped and logged — they entered the
    /// cache before scope injection was in place and cannot be backfilled safely.
    /// `isDimmed` is forced `true`: backfilled entries are completed jobs no longer in
    /// the live feed and must remain visually dimmed.
    func backfillSteps(into cache: inout [Int: ActiveJob]) async {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil else { continue }
            guard cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress }) else { continue }
            guard let scope = cached.scope else {
                log("RunnerPoller › backfillSteps — ⚠️ skipping jobID=\(cacheID) scope is nil (entered cache before scope injection)", category: .runner)
                continue
            }
            guard let data = await ghAPI("repos/\(scope)/actions/jobs/\(cacheID)") else { continue }
            guard let payload = try? decoder.decode(JobPayload.self, from: data) else { continue }
            let updated = await ISO8601DateParser.shared.makeJob(from: payload, isDimmed: true)
            // Restore scope — not present in the API payload, must be carried forward.
            cache[cacheID] = updated.copying(scope: cached.scope)
        }
    }
}
