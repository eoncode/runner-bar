// RunnerPoller.swift
// RunnerBar
//
// Step 10: RunnerStore renamed to RunnerPoller and moved into RunnerBarCore.
// Step 14: applyFetchResult writes only to RunnerState (no viewModel.* writes remain).
// App-layer dependencies replaced with protocol-typed injections and closures
// so Core has no import of the RunnerBar app target.
// F-35: startObservingPreferences and startObservingScopes updated to use
//       ObservationRelay's trailing-closure init (read closure) instead of store: parameter.

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
    //
    // NOTE: Several properties below are `internal` (not `private`) solely to allow
    // extension files in separate source files to read them. All writes must go through
    // `setDisplayState(_:)` (success path) or `applyError(_:)` (failure path) in
    // RunnerPoller+ApplyResult.swift. Swift does not enforce this at the language level
    // for cross-file extensions — the invariant is documented, not mechanically enforced.

    /// Runners currently shown in the panel.
    /// Written exclusively by `applyFetchResult` (success path) and `applyError` (error path).
    private(set) var runners: [Runner] = []
    /// Jobs currently shown in the panel, including dimmed completed entries.
    /// Written exclusively by `applyFetchResult`.
    private(set) var jobs: [ActiveJob] = []
    /// Workflow action groups currently shown in the panel.
    /// Written exclusively by `applyFetchResult`.
    private(set) var actions: [WorkflowActionGroup] = []

    // MARK: ⚠️ Mutable state — write ONLY via applyFetchResult / applyError
    // (RunnerPoller+ApplyResult.swift). Swift cannot enforce this across extension
    // files; the invariant is by convention. Do not write these properties directly
    // from any other extension or call site.

    /// Live-job snapshot from the previous poll, used to detect vanished jobs.
    /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
    var prevLiveJobs: [Int: ActiveJob] = [:]
    /// Completed-job cache keyed by job ID; capped at `PollResultBuilder.jobCacheLimit`.
    /// **In-memory only** — not persisted to disk, not `Codable`. Entries are lost on
    /// app restart; this is intentional (stale cache after restart is better than
    /// persisting potentially scope-nil entries across upgrades).
    /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
    var completedCache: [Int: ActiveJob] = [:]
    /// Live-group snapshot from the previous poll, used to detect vanished groups.
    /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
    var prevLiveGroups: [String: WorkflowActionGroup] = [:]
    /// Group cache keyed by group ID; capped at `PollResultBuilder.groupCacheLimit`.
    /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
    var actionGroupCache: [String: WorkflowActionGroup] = [:]
    /// IDs of action groups whose failure hook has already fired.
    ///
    /// Kept separate from `actionGroupCache` so that cache eviction does not re-arm
    /// the hook for old completed groups still present in GitHub's last-completed feed.
    /// `OrderedSet` preserves insertion order so `trimSeenGroupIDs` evicts the
    /// oldest entries first (FIFO), rather than arbitrary ones as `Set` would.
    /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
    var seenGroupIDs: OrderedSet<String> = []
    /// Whether the GitHub API is currently rate-limiting this client.
    /// Written by `applyFetchResult` and `applyError` (via `RunnerPoller+ApplyResult`).
    private(set) var isRateLimited = false
    /// The exact moment the current rate-limit window expires, or `nil` when no
    /// rate-limit is active or the reset time is unknown.
    /// Assigned in `applyFetchResult`/`applyError` and written to `state`. periphery:ignore
    private(set) var rateLimitResetDate: Date?
    /// Owns the three structured `Task` handles for the poll loop.
    /// `private` — all call sites (startObservingPreferences, startObservingScopes,
    /// start(), isolated deinit) are in this file; no extension file needs access.
    private let pollLoop = PollLoopCoordinator()
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
                let relay = PreferencesObserver(continuation: continuation) {
                    TimeInterval(injectedStore.pollingInterval)
                }
                relay.start()
                return relay
            }
            for await newInterval in stream {
                guard !Task.isCancelled else { break }
                log("RunnerPoller › pollingInterval changed to \(Int(newInterval))s — restarting poll loop", category: .runner)
                await self?.startObservingPreferences()
                guard !Task.isCancelled else { break }
                await self?.start()
                break
            }
            // LOAD-BEARING: keeps the ObservationRelay alive until the for-await loop above
            // exits. Without this, ARC may drop `observer` immediately after the `let`
            // binding above goes out of scope (the Task captures `self` weakly and the relay
            // is not otherwise retained), silently stopping preference-change detection.
            withExtendedLifetime(observer) {}
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
                let relay = ScopesObserver(continuation: continuation) {
                    injectedStore.activeScopes
                }
                relay.start()
                return relay
            }
            for await _ in stream {
                guard !Task.isCancelled else { break }
                log("RunnerPoller › ScopeStore.activeScopes changed — restarting fetch", category: .runner)
                await self?.startObservingScopes()
                guard !Task.isCancelled else { break }
                await self?.start()
                break
            }
            // LOAD-BEARING: keeps the ObservationRelay alive until the for-await loop above
            // exits. Without this, ARC may drop `observer` immediately after the `let`
            // binding above goes out of scope (the Task captures `self` weakly and the relay
            // is not otherwise retained), silently stopping scope-change detection.
            withExtendedLifetime(observer) {}
        }
        pollLoop.setScopeObservationTask(newTask)
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
    func fetch() async {
        do {
            try await fetchInternal()
        } catch {
            log("RunnerPoller › fetch — ⚠️ unhandled error: \(error)", category: .runner)
            await applyError(FetchError(error))
        }
    }

    /// Inner throwing fetch body.
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
        // Derive extra org scopes before buildInstallPathMap so byFullKey covers
        // inferred org scopes as well as user-configured ones. Without this,
        // installPathMap.byFullKey["\(extraOrgScope)/\(runnerName)"] always misses
        // in Phase 2 of fetchAndEnrichRunners, silently skipping metrics for runners
        // whose API id is unresolved and whose name is ambiguous across scopes.
        let extraOrgScopes = deriveExtraOrgScopes(
            from: localRunnersSnapshot,
            configuredScopes: scopesSnapshot
        )
        log("RunnerPoller › fetch — extraOrgScopes=\(extraOrgScopes) (\(extraOrgScopes.count) inferred from local runner gitHubUrl)", category: .runner)
        let allScopes = scopesSnapshot + extraOrgScopes
        let installPathMap = buildInstallPathMap(
            scopes: allScopes,
            localRunners: localRunnersSnapshot
        )
        let enrichedRunners = await fetchAndEnrichRunners(
            scopes: scopesSnapshot,
            extraOrgScopes: extraOrgScopes,
            localRunners: localRunnersSnapshot,
            installPathMap: installPathMap
        )
        // Pass scopesSnapshot directly so fetchAllJobs and fetchActionGroups use the
        // same scope list as the rest of fetchInternal, eliminating the TOCTOU window
        // that would arise from re-reading scopeStore.activeScopes inside those methods.
        let jobResult = await buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            scopes: scopesSnapshot
        )
        let groupResult = await buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            snapSeenGroupIDs: snapSeenGroupIDs,
            jobCache: jobResult.newCache,
            scopes: scopesSnapshot
        )
        await applyFetchResult(
            enrichedRunners: enrichedRunners,
            jobResult: jobResult,
            groupResult: groupResult
        )
    }

    /// Derives extra org scopes from local runner `gitHubUrl` values that are not
    /// already present in the user-configured scope list.
    ///
    /// Only org-scoped URLs (single path component, no "/" in the derived scope)
    /// are returned. Repo-scoped URLs are filtered out by the `!contains("/")` guard.
    /// Duplicates and scopes already in `configuredScopes` are suppressed.
    ///
    /// Extracted from `fetchAndEnrichRunners` Phase 0 so the result is available
    /// before `buildInstallPathMap` is called, allowing `byFullKey` to cover
    /// inferred org scopes as well as user-configured ones.
    func deriveExtraOrgScopes(
        from localRunners: [RunnerModel],
        configuredScopes: [String]
    ) -> [String] {
        let configuredScopeSet = Set(configuredScopes)
        // Use a Set accumulator for O(1) dedup checks (Array.contains is O(n),
        // making the old loop O(n²) in the number of local runners). The parallel
        // `extra` array preserves insertion order for deterministic output.
        var extraSet = Set<String>()
        var extra: [String] = []
        for localRunner in localRunners {
            guard let url = localRunner.gitHubUrl,
                  let derivedScope = scopeFromUrl(url),
                  !derivedScope.contains("/"),
                  !configuredScopeSet.contains(derivedScope),
                  extraSet.insert(derivedScope).inserted
            else { continue }
            extra.append(derivedScope)
            log("RunnerPoller › deriveExtraOrgScopes — derived '\(derivedScope)' from '\(localRunner.runnerName)'", category: .runner)
        }
        return extra
    }

    /// Fetches all active jobs across all scopes concurrently, injecting the source scope
    /// into each job.
    ///
    /// - Parameter scopes: The scope snapshot captured by `fetchInternal` — passed in
    ///   directly to avoid re-reading `scopeStore.activeScopes` and creating a TOCTOU
    ///   window between the snapshot used for runners/groups and the one used for jobs.
    ///
    /// `fetchActiveJobs(for:decoder:)` returns `ActiveJob` values with `scope == nil`
    /// because the GitHub Jobs API payload has no scope field. Without `.copying(scope:)`
    /// at fetch time, every concluded job entering `completedCache` has `scope == nil`.
    /// On the very next `backfillSteps` call those entries would hit the eviction branch
    /// (`scope is nil → removeValue`), causing a one-poll dimmed-job flash on every job
    /// completion — not just once after an upgrade.
    ///
    /// Note: `actionGroupFetcher.fetch(for:cache:)` is **not** used here because it contains
    /// `guard scope.contains("/") else { return [] }`, which silently drops org-scoped jobs.
    /// That guard is correct for group fetching (org-level workflow run endpoints differ),
    /// but the standalone job endpoint handles both scope kinds via `scope.apiPrefix`.
    ///
    /// Results are collected in task-completion order; no downstream consumer depends on
    /// scope-ordering of the returned array.
    ///
    /// `internal` — required for cross-file extension access from `RunnerPoller+PollBridge.swift`;
    /// not a public API. Call sites are exclusively within `RunnerBarCore`.
    func fetchAllJobs(scopes: [String]) async -> [ActiveJob] {
        guard !scopes.isEmpty else { return [] }
        let dec = decoder
        var allJobs: [ActiveJob] = []
        await withTaskGroup(of: [ActiveJob].self) { group in
            for scope in scopes {
                group.addTask {
                    // fetchActiveJobs is a free function in GitHubRunnerFetchers.swift
                    await fetchActiveJobs(for: scope, decoder: dec)
                        .map { $0.copying(scope: scope) }
                }
            }
            for await jobs in group { allJobs.append(contentsOf: jobs) }
        }
        log("RunnerPoller › fetchAllJobs — fetched \(allJobs.count) job(s) across \(scopes.count) scope(s)", category: .runner)
        return allJobs
    }

    /// Fetches workflow action groups for the given scopes concurrently, using the
    /// SHA-keyed cache.
    ///
    /// - Parameter scopes: The scope snapshot captured by `fetchInternal` — passed in
    ///   directly to avoid re-reading `scopeStore.activeScopes` and creating a TOCTOU
    ///   window between the snapshot used for runners/jobs and the one used for groups.
    ///
    /// Results are collected in task-completion order; no downstream consumer depends on
    /// scope-ordering of the returned array.
    ///
    /// `internal` — required for cross-file extension access from `RunnerPoller+PollBridge.swift`;
    /// not a public API. Call sites are exclusively within `RunnerBarCore`.
    func fetchActionGroups(scopes: [String], shaKeyedCache: [String: WorkflowActionGroup]) async -> [WorkflowActionGroup] {
        guard !scopes.isEmpty else { return [] }
        var allGroups: [WorkflowActionGroup] = []
        await withTaskGroup(of: [WorkflowActionGroup].self) { group in
            for scope in scopes {
                group.addTask { await self.actionGroupFetcher.fetch(for: scope, cache: shaKeyedCache) }
            }
            for await groups in group { allGroups.append(contentsOf: groups) }
        }
        log("RunnerPoller › fetchActionGroups — fetched \(allGroups.count) group(s) across \(scopes.count) scope(s)", category: .runner)
        return allGroups
    }

    /// Backfills step data into the completed-job cache.
    ///
    /// Iterates jobs in `cache` that have a conclusion but missing or in-progress steps,
    /// fetches the full job payload from the GitHub API, and updates the cache entry.
    ///
    /// **Eviction rationale — these are NOT data-loss bugs:**
    /// Three categories of cache entry are evicted (via `removeValue`) rather than
    /// skipped or retried. Each is intentional and self-correcting:
    ///
    /// 1. **`scope == nil` (pre-scope-injection entries)**
    ///    Written before scope-injection was introduced (pre-F-26). As of F-26,
    ///    `fetchAllJobs` always injects scope via `.copying(scope:)` at fetch time,
    ///    so `scope == nil` entries should only appear in the first poll cycle after
    ///    an upgrade from a pre-F-26 build. Evicting them prevents repeated per-poll
    ///    warning spam. They re-enter the cache with correct scope data on the next
    ///    poll cycle once a new live fetch completes. This flash is cosmetic and
    ///    self-corrects within one poll cycle.
    ///    TODO: Remove this guard after two release cycles once pre-F-26 cache
    ///    entries are definitively gone from the field.
    ///
    /// 2. **Org-only scope (`!scope.contains("/")`)**
    ///    The GitHub Jobs API has no `orgs/{org}/actions/jobs/{id}` endpoint — only
    ///    `repos/{owner}/{repo}/actions/jobs/{id}`. Keeping these entries would log a
    ///    warning every poll cycle with no path to ever resolve them. Eviction is a
    ///    one-time operation; the entry cannot re-populate via any backfill path
    ///    (no GitHub org/actions/jobs endpoint exists).
    ///
    /// 3. **Empty-steps API response**
    ///    Early-queued jobs may return zero steps transiently. The guard
    ///    `guard !updated.steps.isEmpty` keeps the existing cache entry unchanged and
    ///    retries on the next poll — this is a *skip*, not an eviction.
    ///
    /// The `removeValue` calls for cases 1 and 2 are therefore intentional, not data loss.
    func backfillSteps(into cache: inout [Int: ActiveJob]) async {
        for cacheID in Array(cache.keys) {
            guard let cached = cache[cacheID] else { continue }
            guard cached.conclusion != nil else { continue }
            guard cached.steps.isEmpty || cached.steps.contains(where: { $0.status == .inProgress }) else { continue }
            guard let scope = cached.scope else {
                cache.removeValue(forKey: cacheID)
                log("RunnerPoller › backfillSteps — evicted jobID=\(cacheID): scope is nil (pre-scope-injection entry)", category: .runner)
                continue
            }
            guard scope.contains("/") else {
                cache.removeValue(forKey: cacheID)
                // swiftlint:disable:next line_length
                log("RunnerPoller › backfillSteps — evicted jobID=\(cacheID): org-only scope '\(scope)' has no repo path; org-only jobs cannot be backfilled (no GitHub org/actions/jobs endpoint)", category: .runner)
                continue
            }
            guard let data = await ghAPI("repos/\(scope)/actions/jobs/\(cacheID)") else { continue }
            do {
                let payload = try decoder.decode(JobPayload.self, from: data)
                let updated = await ISO8601DateParser.shared.makeJob(from: payload, isDimmed: true)
                // Guard against an empty-steps API response clobbering valid cached steps.
                // Early-queued jobs may return a payload with zero steps; in that case
                // preserve the existing cache entry unchanged and retry on the next poll.
                guard !updated.steps.isEmpty else {
                    log("RunnerPoller › backfillSteps — jobID=\(cacheID) API returned 0 steps, keeping existing cache entry", category: .runner)
                    continue
                }
                // Restore scope — not present in the API payload, must be carried forward.
                cache[cacheID] = updated.copying(scope: cached.scope)
            } catch {
                log("RunnerPoller › backfillSteps — ⚠️ decode failed for jobID=\(cacheID): \(error)", category: .runner)
            }
        }
    }

    // MARK: - Private(set) write-through

    /// Sets the actor-local display properties in a single controlled call.
    ///
    /// **Scope:** this function manages `runners`, `jobs`, `actions`, `isRateLimited`,
    /// and `rateLimitResetDate` only. The five poll-cycle state properties
    /// (`completedCache`, `prevLiveJobs`, `actionGroupCache`, `prevLiveGroups`,
    /// `seenGroupIDs`) are written directly by `applyFetchResult` before calling this
    /// function — they are not routed through `setDisplayState` because they are not
    /// display properties and have no partial-update semantics.
    ///
    /// **Partial-update contract:** `runners`, `jobs`, and `actions` are optional.
    /// Passing `nil` for any of these means "leave the current value unchanged" —
    /// it does **not** clear the list. `isRateLimited` and `rateLimitResetDate` are
    /// non-optional and are **always** updated on every call.
    ///
    /// This asymmetry is intentional: `applyError` calls this function with
    /// `runners/jobs/actions` all `nil` to preserve stale display data during an
    /// error cycle (views continue to show the last known state). Do not call this
    /// function with `nil` display lists intending to clear them — use explicit
    /// empty arrays instead.
    ///
    /// `private(set)` prevents arbitrary writes from outside the actor, but Swift's
    /// file-scoped `private` means extension files in separate source files cannot
    /// write these properties either. This internal setter is therefore the controlled
    /// mutation path for display properties, used exclusively by `applyFetchResult`
    /// and `applyError` (in `RunnerPoller+ApplyResult.swift`).
    func setDisplayState(
        runners newRunners: [Runner]? = nil,
        jobs newJobs: [ActiveJob]? = nil,
        actions newActions: [WorkflowActionGroup]? = nil,
        isRateLimited newIsRateLimited: Bool,
        rateLimitResetDate newResetDate: Date?
    ) {
        if let newRunners { runners = newRunners }
        if let newJobs { jobs = newJobs }
        if let newActions { actions = newActions }
        isRateLimited = newIsRateLimited
        rateLimitResetDate = newResetDate
    }
}
