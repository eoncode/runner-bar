// RunnerPoller.swift
// RunnerBarCore
//
// Step 10: RunnerStore renamed to RunnerPoller and moved into RunnerBarCore.
// Step 14: applyFetchResult writes only to RunnerState (no viewModel.* writes remain).
// App-layer dependencies replaced with protocol-typed injections and closures
// so Core has no import of the RunnerBar app target.

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
    private var seenGroupIDs: Set<String> = []
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
    let fireFailureHook: @Sendable (_ group: WorkflowActionGroup, _ scope: String) async -> Void
    /// Injected preferences store. Provides `pollingInterval`.
    private let preferencesStore: any AppPreferencesStoreProtocol
    /// Injected scope store. Provides `activeScopes`.
    /// `internal` (not `private`) so that extension files can read this property.
    internal let scopeStore: any ScopeStoreProtocol
    /// Shared `JSONDecoder` — reused across all decode calls in the actor.
    let decoder = JSONDecoder()
    /// Fetcher for workflow action groups.
    let actionGroupFetcher: any WorkflowActionGroupFetcherProtocol

    // MARK: - Aggregate status

    /// The combined health status across all runners, derived from the current `runners` array.
    /// periphery:ignore
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    // MARK: - Init

    /// Designated init for dependency injection.
    ///
    /// - Parameters:
    ///   - state: The observable read model that views and AppDelegate observe.
    ///   - preferencesStore: Provides `pollingInterval`.
    ///   - scopeStore: Provides `activeScopes`.
    ///   - localRunners: Closure returning the current local-runner snapshot on `@MainActor`.
    ///   - applyMetrics: Closure that writes enriched metrics back to the local runner store.
    ///   - actionGroupFetcher: Fetcher for workflow action groups.
    public init(
        state: RunnerState,
        preferencesStore: any AppPreferencesStoreProtocol,
        scopeStore: any ScopeStoreProtocol,
        localRunners: @escaping @MainActor @Sendable () -> [RunnerModel],
        applyMetrics: @escaping @Sendable (_ metrics: RunnerMetrics?, _ runnerId: Int, _ name: String) async -> Void,
        fireFailureHook: @escaping @Sendable (_ group: WorkflowActionGroup, _ scope: String) async -> Void = { _, _ in },
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
    private func startObservingPreferences() {
        let injectedStore = preferencesStore
        pollLoop.setIntervalObservationTask(Task { [weak self] in
            let (stream, continuation) = AsyncStream<TimeInterval>.makeStream()
            let observer: PreferencesObserver = await MainActor.run {
                let preferencesObserver = PreferencesObserver(continuation: continuation, store: injectedStore)
                preferencesObserver.start()
                return preferencesObserver
            }
            for await newInterval in stream {
                guard !Task.isCancelled else { break }
                log("RunnerPoller › pollingInterval changed to \(newInterval) — restarting poll loop")
                await self?.startObservingPreferences()
                guard !Task.isCancelled else { break }
                await self?.start()
                break
            }
            _ = observer
        })
    }

    /// Starts (or restarts) the `activeScopes` observation loop.
    private func startObservingScopes() {
        let injectedStore = scopeStore
        pollLoop.setScopeObservationTask(Task { [weak self] in
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
        })
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
        log("RunnerPoller › start — previous pollTask cancelled, launching new task")
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
    private func nextPollInterval() async -> TimeInterval {
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions = actions.contains { $0.groupStatus == .inProgress || $0.groupStatus == .queued }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, await MainActor.run { preferencesStore.pollingInterval })
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerPoller › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle)")
        return interval
    }

    // MARK: - Fetch

    /// Performs one full poll cycle.
    public func fetch() async {
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
        }
    }

    // MARK: - fetchAndEnrichRunners

    /// Fetches runners for the given scopes, resolves install paths, and enriches with metrics.
    ///
    /// Both phases run concurrently:
    /// 1. Scope fetches — one child task per scope via `withTaskGroup`.
    /// 2. Metrics enrichment — one child task per busy runner via a second `withTaskGroup`.
    /// This restores the parallel behaviour from the original `RunnerStore` implementation;
    /// a serial loop would add latency proportional to the number of concurrently-busy runners.
    ///
    /// The `scope` is preserved alongside each runner through both phases so that Phase 2
    /// can form the correct composite `"<scope>/<name>"` key for the `byFullKey` fallback.
    func fetchAndEnrichRunners(
        scopes: [String],
        localRunners: [RunnerModel],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        log("RunnerPoller › fetchAndEnrichRunners ENTER — scopes=\(scopes)")

        // Phase 1 — Fetch raw runners for all scopes in parallel.
        // Each element retains its source scope so Phase 2 can form the
        // "<scope>/<runnerName>" composite key for the byFullKey fallback.
        var indexed: [(idx: Int, scope: String, runner: Runner)] = []
        await withTaskGroup(of: (Int, String, [Runner]).self) { group in
            for (i, scope) in scopes.enumerated() {
                group.addTask {
                    let fetched = await fetchRunners(for: scope)
                    return (i, scope, fetched)
                }
            }
            for await (i, scope, fetched) in group {
                indexed.append(contentsOf: fetched.map { (i, scope, $0) })
            }
        }

        // Phase 2 — Enrich each busy runner with system metrics (CPU, memory) concurrently.
        // Using a second withTaskGroup restores the parallel behaviour from RunnerStore;
        // a serial loop would serialise all metricsForRunner() calls even when multiple
        // runners are busy simultaneously.
        let busyIndices = indexed.indices.filter { indexed[$0].runner.busy }
        if !busyIndices.isEmpty {
            // Collect (arrayIndex, metrics) pairs concurrently, then apply in order.
            let metricsResults: [(Int, RunnerMetrics?)] = await withTaskGroup(
                of: (Int, RunnerMetrics?).self
            ) { group in
                for i in busyIndices {
                    let runner = indexed[i].runner
                    let scope = indexed[i].scope
                    // Resolve install path using all four available lookup keys, in order
                    // of decreasing specificity:
                    //   1. byApiId    — most precise; matches the GitHub REST runner ID.
                    //   2. byAgentId  — matches the runner's self-reported agent ID.
                    //   3. byName     — matches on runner name alone (scope-agnostic).
                    //   4. byFullKey  — matches on "<scope>/<runnerName>" composite key;
                    //                   resolves ambiguity when two runners in different
                    //                   scopes share the same name and neither apiId nor
                    //                   agentId is resolvable from local runner metadata.
                    let installPath = installPathMap.byApiId[runner.id]
                        ?? installPathMap.byAgentId[runner.id]
                        ?? installPathMap.byName[runner.name]
                        ?? installPathMap.byFullKey["\(scope)/\(runner.name)"]
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

        // Write metrics back to the injected local runner store closure.
        let metricsUpdates = indexed.filter { entry in
            entry.runner.busy && (
                installPathMap.byApiId[entry.runner.id] != nil
                    || installPathMap.byAgentId[entry.runner.id] != nil
                    || installPathMap.byName[entry.runner.name] != nil
                    || installPathMap.byFullKey["\(entry.scope)/\(entry.runner.name)"] != nil
            )
        }
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
