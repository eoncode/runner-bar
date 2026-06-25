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

// MARK: - IndexedScopedRunner

/// Carries a scope-fetched `Runner` alongside its source-scope string.
/// Used internally by `fetchAndEnrichRunners` to pass data through two
/// concurrent `withTaskGroup` phases without a 3-member tuple
/// (which would trigger the `large_tuple` SwiftLint rule).
///
/// ⚠️ The ordering of entries in the `indexed` array after Phase 1 is
/// non-deterministic: `withTaskGroup` tasks complete in arrival order.
/// This matches the previous `RunnerStore` behaviour; views sort
/// runners independently for display.
private struct IndexedScopedRunner {
    /// The GitHub scope URL string (repo or org) this runner belongs to.
    var scope: String
    /// The enriched `Runner` value. Mutated in-place during Phase 2 to add metrics.
    var runner: Runner
}

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
    private(set) var runners: [Runner] = []
    /// Jobs currently shown in the panel, including dimmed completed entries.
    private(set) var jobs: [ActiveJob] = []
    /// Workflow action groups currently shown in the panel.
    private(set) var actions: [WorkflowActionGroup] = []
    /// Live-job snapshot from the previous poll, used to detect vanished jobs.
    private var prevLiveJobs: [Int: ActiveJob] = [:]
    /// Completed-job cache keyed by job ID; capped at `PollResultBuilder.jobCacheLimit`.
    private var completedCache: [Int: ActiveJob] = [:]
    /// Live-group snapshot from the previous poll, used to detect vanished groups.
    private var prevLiveGroups: [String: WorkflowActionGroup] = [:]
    /// Group cache keyed by group ID; capped at `PollResultBuilder.groupCacheLimit`.
    private var actionGroupCache: [String: WorkflowActionGroup] = [:]
    /// IDs of action groups whose failure hook has already fired.
    ///
    /// Kept separate from `actionGroupCache` so that cache eviction does not re-arm
    /// the hook for old completed groups still present in GitHub's last-completed feed.
    /// `OrderedSet` preserves insertion order so `trimSeenGroupIDs` evicts the
    /// oldest entries first (FIFO), rather than arbitrary ones as `Set` would.
    private var seenGroupIDs: OrderedSet<String> = []
    /// Whether the GitHub API is currently rate-limiting this client.
    private(set) var isRateLimited = false
    /// The exact moment the current rate-limit window expires, or `nil` when no
    /// rate-limit is active or the reset time is unknown.
    /// Assigned in `applyFetchResult` and written to `state`. periphery:ignore
    private(set) var rateLimitResetDate: Date?
    /// Owns the three structured `Task` handles for the poll loop.
    private let pollLoop = PollLoopCoordinator()
    /// Observable read model — the source of truth for all views and AppDelegate observers.
    public let state: RunnerState
    /// Returns the current local-runner snapshot on the `@MainActor`.
    /// Injected at init so the actor body never imports the app-layer `LocalRunnerStore`.
    private let localRunners: @MainActor @Sendable () -> [RunnerModel]
    /// Writes metrics back into the local runner store.
    /// Injected at init to decouple Core from the app-layer `LocalRunnerStore` actor.
    private let applyMetrics: @Sendable (_ metrics: RunnerMetrics?, _ runnerId: Int, _ name: String) async -> Void
    /// Fires a failure hook for a newly-failed workflow action group.
    /// Injected at init so Core never imports the app-layer `FailureHookRunner`.
    /// `internal` so that extension files (e.g. `RunnerPoller+PollBridge`) can call it.
    let fireFailureHook: @Sendable (_ group: WorkflowActionGroup, _ scope: String) async -> Void
    /// Injected preferences store. Provides `pollingInterval`.
    private let preferencesStore: any AppPreferencesStoreProtocol
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

    // MARK: - Observation loops

    /// Starts (or restarts) the `pollingInterval` observation loop.
    ///
    /// Uses `AsyncStream<TimeInterval>` to match `PreferencesObserver.continuation` which is
    /// typed `AsyncStream<TimeInterval>.Continuation` and yields
    /// `TimeInterval(store.pollingInterval)`. The stream element type must match the
    /// continuation type exactly — `pollingInterval` is an `Int` (seconds) but the observer
    /// converts it to `TimeInterval` before yielding so the value can be used directly in
    /// `nextPollInterval()` without a second conversion.
    ///
    /// **Self-cancellation avoidance**
    /// `setIntervalObservationTask(newTask)` cancels the *previous* interval-observation
    /// task and installs `newTask` as the new one. When called recursively from inside the
    /// for-await body, the calling task must therefore create the new `Task` *before* passing
    /// it to `setIntervalObservationTask` — otherwise the setter would cancel the caller
    /// itself and the subsequent `start()` call would never execute.
    private func startObservingPreferences() {
        let injectedStore = preferencesStore
        let newTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<TimeInterval>.makeStream()
            let observer: PreferencesObserver = await MainActor.run {
                let preferencesObserver = PreferencesObserver(continuation: continuation, store: injectedStore)
                preferencesObserver.start()
                return preferencesObserver
            }
            for await newInterval in stream {
                guard !Task.isCancelled else { break }
                log("RunnerPoller › pollingInterval changed to \(Int(newInterval))s — restarting poll loop")
                await self?.startObservingPreferences()
                guard !Task.isCancelled else { break }
                await self?.start()
                break
            }
            _ = observer
        }
        pollLoop.setIntervalObservationTask(newTask)
    }

    /// Starts (or restarts) the `activeScopes` observation loop.
    ///
    /// **Self-cancellation avoidance**
    /// Same pattern as `startObservingPreferences`: the new `Task` is created first,
    /// then handed to `setScopeObservationTask` so the setter cancels the *previous*
    /// task rather than the one currently executing.
    private func startObservingScopes() {
        let injectedStore = scopeStore
        let newTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<[String]>.makeStream()
            let observer: ScopesObserver = await MainActor.run {
                let scopesObserver = ScopesObserver(continuation: continuation, store: injectedStore)
                scopesObserver.start()
                return scopesObserver
            }
            for await _ in stream {
                guard !Task.isCancelled else { break }
                log("RunnerPoller › ScopeStore.activeScopes changed — restarting fetch")
                await self?.startObservingScopes()
                guard !Task.isCancelled else { break }
                await self?.start()
                break
            }
            _ = observer
        }
        pollLoop.setScopeObservationTask(newTask)
    }

    // MARK: - Poll loop

    /// Starts (or restarts) the structured async poll loop.
    public func start() async {
        let scopes = await MainActor.run { scopeStore.activeScopes }
        log("RunnerPoller › start — activeScopes=\(scopes)")
        if scopes.isEmpty {
            log("RunnerPoller › ⚠️ start called but activeScopes is EMPTY — actions will not load")
        }
        let localCount = await MainActor.run { localRunners().count }
        log("RunnerPoller › start — localRunners.count=\(localCount) at start() time")
        if localCount == 0 {
            log("RunnerPoller › ⚠️ start — localRunners=0 at start time; installPathMap will be empty on first fetch.")
        }
        log("RunnerPoller › start — previous pollTask cancelled, launching new poll task")
        pollLoop.setPollTask(Task { [weak self] in
            guard let self else { return }
            await self.fetch()
            while !Task.isCancelled {
                let interval = await self.nextPollInterval()
                log("RunnerPoller › poll loop — next fetch in \(Int(interval))s")
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch is CancellationError {
                    log("RunnerPoller › poll loop — CancellationError, exiting cleanly")
                    break
                } catch {
                    log("RunnerPoller › poll loop — unexpected error \(error), exiting")
                    break
                }
                guard !Task.isCancelled else {
                    log("RunnerPoller › poll loop — cancelled after sleep, exiting")
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
        log("RunnerPoller › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle)")
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
            log("RunnerPoller › fetch — ⚠️ unhandled error: \(error)")
            await applyError(FetchError(error))
        }
    }

    /// Inner throwing fetch body. Extracted so `fetch()` can wrap it cleanly in `do/catch`.
    private func fetchInternal() async throws {
        await clearGhRateLimit()
        let scopesSnapshot = await MainActor.run { scopeStore.activeScopes }
        log("RunnerPoller › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerPoller › ⚠️ fetch — activeScopes snapshot is EMPTY")
        }
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache
        let snapSeenGroupIDs = seenGroupIDs
        let localRunnersSnapshot = await MainActor.run { localRunners() }
        log("RunnerPoller › fetch — localRunners.count=\(localRunnersSnapshot.count) (used for installPathMap)")
        if localRunnersSnapshot.isEmpty {
            log("RunnerPoller › ⚠️ fetch — localRunners is EMPTY; installPathMap will be empty")
        } else {
#if DEBUG
            log("RunnerPoller › fetch — localRunners=\(localRunnersSnapshot.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })")
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

    // MARK: - Apply result

    /// Merges a completed fetch into actor state and pushes the snapshot to `RunnerState`.
    ///
    /// Clears `state.fetchError` on every successful cycle so the UI error banner
    /// dismisses automatically as soon as connectivity is restored. The write is
    /// guarded — if `fetchError` is already `nil` the assignment is skipped to
    /// avoid a spurious `@Observable` notification on every healthy poll cycle.
    private func applyFetchResult(
        enrichedRunners: [Runner],
        jobResult: JobPollResult,
        groupResult: GroupPollResult
    ) async {
        let rateLimitSnapshot = await ghRateLimitSnapshot()
        runners = enrichedRunners
        jobs = jobResult.display
        completedCache = jobResult.newCache
        prevLiveJobs = jobResult.newPrevLive
        actions = groupResult.display
        actionGroupCache = groupResult.newGroupCache
        prevLiveGroups = groupResult.newPrevLiveGroups
        seenGroupIDs = groupResult.newSeenGroupIDs
        isRateLimited = rateLimitSnapshot.isLimited
        rateLimitResetDate = rateLimitSnapshot.resetDate
        // swiftlint:disable:next line_length
        log("RunnerPoller › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) runners=\(enrichedRunners.count) isRateLimited=\(rateLimitSnapshot.isLimited) rateLimitResetDate=\(String(describing: rateLimitSnapshot.resetDate))")
        await MainActor.run { [state] in
            state.runners = enrichedRunners
            state.jobs = jobResult.display
            state.actions = groupResult.display
            state.isRateLimited = rateLimitSnapshot.isLimited
            state.rateLimitResetDate = rateLimitSnapshot.resetDate
            if state.fetchError != nil { state.fetchError = nil }
        }
    }

    /// Sendable-safe wrapper that bridges an arbitrary `any Error` across an actor boundary.
    ///
    /// `any Error` is not `Sendable`, so passing it directly into `MainActor.run`
    /// produces a warning under `-strict-concurrency=complete`. `FetchError` captures
    /// `localizedDescription` — the only field read by `fetchErrorBanner` — and
    /// re-surfaces it as a `LocalizedError` conformance so the message is preserved.
    private struct FetchError: LocalizedError, Sendable {
        /// The user-facing description forwarded from the underlying error.
        let errorDescription: String?
        /// Wraps `underlying`, capturing its `localizedDescription` as a `Sendable` string.
        init(_ underlying: any Error) { errorDescription = underlying.localizedDescription }
    }

    /// Surfaces a fetch failure to the `RunnerState` read model.
    ///
    /// Mirrors `applyFetchResult` by updating both the actor-local rate-limit copies
    /// (`self.isRateLimited`, `self.rateLimitResetDate` — read by `nextPollInterval()`)
    /// and the `@Observable` read model (`state.*` — read by the view layer).
    /// Without this sync, a failed cycle while rate-limited would leave the actor-local
    /// copies stale, causing `nextPollInterval()` to compute the wrong cadence until the
    /// next successful `applyFetchResult`.
    ///
    /// Snapshots rate-limit state so the UI never shows both banners simultaneously:
    /// `clearGhRateLimit()` at the top of `fetchInternal()` clears the internal actor
    /// before any throw, so this snapshot reflects the cleared state.
    ///
    /// The `fetchError` write is guarded by a `localizedDescription` comparison to avoid
    /// re-notifying `@Observable` observers on every failed cycle when the message is
    /// unchanged (e.g. sustained network loss).
    ///
    /// Intentionally does **not** clear `runners`, `jobs`, or `actions` — views show
    /// stale data alongside the error banner rather than an empty list.
    private func applyError(_ error: any Error & Sendable) async {
        let rateLimitSnapshot = await ghRateLimitSnapshot()
        // Sync actor-local copies first — nextPollInterval() reads these directly.
        isRateLimited = rateLimitSnapshot.isLimited
        rateLimitResetDate = rateLimitSnapshot.resetDate
        await MainActor.run { [state] in
            // Guard the write: `any Error` is not Equatable, so compare via
            // `localizedDescription` — the only field `fetchErrorBanner` consumes.
            // Skipping the write when the message is unchanged avoids a spurious
            // `@Observable` notification on every failed poll cycle.
            if state.fetchError?.localizedDescription != error.localizedDescription {
                state.fetchError = error
            }
            state.isRateLimited = rateLimitSnapshot.isLimited
            state.rateLimitResetDate = rateLimitSnapshot.resetDate
        }
    }

    // MARK: - fetchAndEnrichRunners

    /// Fetches runners for the given scopes, resolves install paths, and enriches with metrics.
    ///
    /// `internal` — `fetch()` is the public entry point; this method is an implementation
    /// detail not intended for direct external calls.
    ///
    /// **Phase 0** derives extra org scopes from local runners whose `gitHubUrl` points to a
    /// single-path-component URL (org-only, not repo). This handles runners registered against
    /// an org that the user hasn't explicitly added as a scope in ScopeStore — their org is
    /// inferred from the local runner's URL so those runners continue to appear in the panel.
    ///
    /// **Phase 1** fans out concurrent scope fetches via `withTaskGroup`. Task completion order
    /// is non-deterministic; views sort runners for display independently.
    ///
    /// **Phase 2** enriches each busy runner with system metrics concurrently.
    ///
    /// **Install-path lookup priority** (matches the original `RunnerStore`):
    /// `byApiId ?? byAgentId ?? byFullKey ?? byName`
    /// `byFullKey` ("scope/name" composite) ranks above `byName` so runners sharing
    /// a name across different scopes resolve to the correct install path.
    ///
    /// - Parameters:
    ///   - scopes: The active scopes to fetch runners for.
    ///   - localRunners: The current local-runner snapshot (used for org-scope derivation).
    ///   - installPathMap: Pre-built lookup maps from `buildInstallPathMap`.
    internal func fetchAndEnrichRunners(
        scopes: [String],
        localRunners: [RunnerModel],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        log("RunnerPoller › fetchAndEnrichRunners ENTER — scopes=\(scopes)")

        // MARK: Phase 0 — Extra org-scope derivation from local runner URLs
        // Delegates to `scopeFromUrl(_:)` in GitHubURLHelpers (F-52).
        // Only org-scoped URLs produce a scope string without a "/"; repo-scoped
        // URLs ("owner/repo") are filtered out by the `!contains("/")` guard below.
        let configuredScopeSet = Set(scopes)
        var extraOrgScopes: [String] = []
        for localRunner in localRunners {
            guard let url = localRunner.gitHubUrl,
                  let derivedScope = scopeFromUrl(url),
                  !derivedScope.contains("/") else { continue }
            let orgScope = derivedScope
            guard !configuredScopeSet.contains(orgScope),
                  !extraOrgScopes.contains(orgScope)
            else { continue }
            extraOrgScopes.append(orgScope)
            log("RunnerPoller › fetchAndEnrichRunners — derived extra org scope '\(orgScope)' from local runner '\(localRunner.runnerName)'")
        }
        if !extraOrgScopes.isEmpty {
            log("RunnerPoller › fetchAndEnrichRunners — extra org scopes to fetch: \(extraOrgScopes)")
        }

        let allScopes = scopes + extraOrgScopes

        // MARK: Phase 1 — Fetch raw runners for all scopes concurrently
        var indexed: [IndexedScopedRunner] = []
        await withTaskGroup(of: (String, [Runner]).self) { group in
            for scope in allScopes {
                group.addTask {
                    let fetched = await fetchRunners(for: scope, decoder: self.decoder)
                    return (scope, fetched)
                }
            }
            for await (scope, fetched) in group {
                indexed.append(contentsOf: fetched.map { IndexedScopedRunner(scope: scope, runner: $0) })
            }
        }

        // MARK: Phase 2 — Enrich each busy runner with system metrics concurrently
        // Lookup priority: byApiId ?? byAgentId ?? byFullKey ?? byName
        let busyIndices = indexed.indices.filter { indexed[$0].runner.busy }
        if !busyIndices.isEmpty {
            let metricsResults: [(Int, RunnerMetrics?)] = await withTaskGroup(
                of: (Int, RunnerMetrics?).self
            ) { group in
                for i in busyIndices {
                    let runner = indexed[i].runner
                    let scope = indexed[i].scope
                    let installPath = installPathMap.byApiId[runner.id]
                        ?? installPathMap.byAgentId[runner.id]
                        ?? installPathMap.byFullKey["\(scope)/\(runner.name)"]
                        ?? installPathMap.byName[runner.name]
                    guard let path = installPath else {
                        log("RunnerPoller › fetchAndEnrichRunners — no installPath for \(runner.name) id=\(runner.id) scope=\(scope)")
                        continue
                    }
                    group.addTask {
                        let metrics = await metricsForRunner(installPath: path)
                        return (i, metrics)
                    }
                }
                var results: [(Int, RunnerMetrics?)] = []
                for await pair in group { results.append(pair) }
                return results
            }
            for (i, metrics) in metricsResults {
                indexed[i].runner = indexed[i].runner.copying(metrics: metrics)
            }
        }

        let metricsUpdates = indexed.filter { $0.runner.busy && $0.runner.metrics != nil }
        if !metricsUpdates.isEmpty {
            for entry in metricsUpdates {
#if DEBUG
                log("RunnerPoller › fetchAndEnrichRunners — applyMetrics: \(entry.runner.name) id=\(entry.runner.id) busy=\(entry.runner.busy) metrics=\(String(describing: entry.runner.metrics))")
#endif
                await applyMetrics(entry.runner.metrics, entry.runner.id, entry.runner.name)
            }
        }

        let result = indexed.map(\.runner)
        log("RunnerPoller › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
