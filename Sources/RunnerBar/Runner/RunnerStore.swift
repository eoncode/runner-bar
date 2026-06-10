// RunnerStore.swift
// RunnerBar
import AppKit
import Foundation
import RunnerBarCore

// MARK: - RunnerStore

/// Swift 6 actor that owns the GitHub poll loop and all derived runner/job/action state.
///
/// **Concurrency model**
/// - The actor runs on its own executor (background thread).
/// - `AppPreferencesStore` and `ScopeStore` are `@MainActor`; any read of their
///   properties must happen inside `await MainActor.run { }` or a `Task { @MainActor in }`.
/// - After every fetch cycle, results are pushed to the injected `RunnerViewModel` on the
///   main actor via `await MainActor.run { }`. SwiftUI's `@Observable` machinery
///   picks up the mutation automatically — no Combine `PassthroughSubject` needed.
/// - `LocalRunnerStore` is `@MainActor`; reads are wrapped in `await MainActor.run { }`.
actor RunnerStore {

    // MARK: - State

    private(set) var runners: [Runner] = []
    private(set) var jobs: [ActiveJob] = []
    private(set) var actions: [WorkflowActionGroup] = []

    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]
    private var prevLiveGroups: [String: WorkflowActionGroup] = [:]
    private var actionGroupCache: [String: WorkflowActionGroup] = [:]
    /// IDs of action groups whose failure hook has already fired.
    private var seenGroupIDs: Set<String> = []

    private(set) var isRateLimited = false
    private(set) var rateLimitResetDate: Date?

    private var pollTask: Task<Void, Never>?
    private var intervalObservationTask: Task<Void, Never>?
    private var scopeObservationTask: Task<Void, Never>?

    /// The view model this store pushes updates into.
    private let viewModel: RunnerViewModel
    /// Injected reference to the local runner store — avoids singleton cross-references
    /// inside the actor body (Swift 6 / PR #1303 requirement).
    private let localRunnerStore: LocalRunnerStore

    // MARK: - Aggregate status

    var aggregateStatus: AggregateStatus { AggregateStatus(runners: runners) }

    // MARK: - Init

    /// Designated init for dependency injection.
    init(viewModel: RunnerViewModel, localRunnerStore: LocalRunnerStore) {
        self.viewModel = viewModel
        self.localRunnerStore = localRunnerStore
        Task { [weak self] in await self?._startObservingPreferences() }
        Task { [weak self] in await self?._startObservingScopes() }
    }

    // MARK: - Observation helpers (actor-isolated entry points)

    /// Called from `Task` in init; safe because it's actor-isolated.
    func _startObservingPreferences() {
        intervalObservationTask?.cancel()
        intervalObservationTask = Task { [weak self] in
            // Build an AsyncStream that fires on every pollingInterval change.
            // withObservationTracking must run on @MainActor because
            // AppPreferencesStore is @MainActor.
            let stream: AsyncStream<Int> = AsyncStream { continuation in
                @Sendable func observe() {
                    // Each call to withObservationTracking registers one onChange.
                    // We re-register inside onChange to get subsequent changes.
                    MainActor.assumeIsolated {
                        withObservationTracking {
                            _ = AppPreferencesStore.shared.pollingInterval
                        } onChange: {
                            Task { @MainActor in
                                continuation.yield(AppPreferencesStore.shared.pollingInterval)
                            }
                            observe()
                        }
                    }
                }
                // Prime the observation on the main thread.
                Task { @MainActor in observe() }
            }
            var isFirst = true
            for await newInterval in stream {
                if isFirst { isFirst = false; continue }
                guard !Task.isCancelled else { return }
                log("RunnerStore › pollingInterval changed to \(newInterval) — restarting poll loop")
                await self?.start()
            }
        }
    }

    /// Called from `Task` in init; safe because it's actor-isolated.
    func _startObservingScopes() {
        scopeObservationTask?.cancel()
        scopeObservationTask = Task { [weak self] in
            let stream: AsyncStream<[String]> = AsyncStream { continuation in
                @Sendable func observe() {
                    MainActor.assumeIsolated {
                        withObservationTracking {
                            _ = ScopeStore.shared.activeScopes
                        } onChange: {
                            Task { @MainActor in
                                continuation.yield(ScopeStore.shared.activeScopes)
                            }
                            observe()
                        }
                    }
                }
                Task { @MainActor in observe() }
            }
            var isFirst = true
            for await _ in stream {
                if isFirst { isFirst = false; continue }
                guard !Task.isCancelled else { return }
                log("RunnerStore › ScopeStore.activeScopes changed — restarting fetch")
                await self?.start()
            }
        }
    }

    // MARK: - Poll loop

    /// Starts (or restarts) the structured async poll loop.
    ///
    /// Safe to call multiple times — the previous task is always cancelled first.
    func start() {
        let scopes = MainActor.assumeIsolated { ScopeStore.shared.activeScopes }
        log("RunnerStore › start — activeScopes=\(scopes)")
        if scopes.isEmpty {
            log("RunnerStore › ⚠️ start called but activeScopes is EMPTY — actions will not load")
        }
        let localCount = MainActor.assumeIsolated { localRunnerStore.runners.count }
        log("RunnerStore › start — localRunnerStore.runners.count=\(localCount) at start() time")
        if localCount == 0 {
            log("RunnerStore › ⚠️ start — localRunners=0 at start time; installPathMap will be empty on first fetch.")
        }
        pollTask?.cancel()
        log("RunnerStore › start — previous pollTask cancelled, launching new task")
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.fetch()
            while !Task.isCancelled {
                let interval = await self.nextPollInterval()
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

    private func nextPollInterval() -> TimeInterval {
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions = actions.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, MainActor.assumeIsolated { AppPreferencesStore.shared.pollingInterval })
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle)")
        return interval
    }

    // MARK: - Fetch

    func fetch() async {
        await clearGhRateLimit()

        let scopesSnapshot = await MainActor.run { ScopeStore.shared.activeScopes }
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY")
        }

        let snapPrev         = prevLiveJobs
        let snapCache        = completedCache
        let snapPrevGroups   = prevLiveGroups
        let snapGroupCache   = actionGroupCache
        let snapSeenGroupIDs = seenGroupIDs
        let localRunners     = await MainActor.run { localRunnerStore.runners }
        log("RunnerStore › fetch — localRunners.count=\(localRunners.count) (used for installPathMap)")
        if localRunners.isEmpty {
            log("RunnerStore › ⚠️ fetch — localRunners is EMPTY; installPathMap will be empty")
        } else {
#if DEBUG
            log("RunnerStore › fetch — localRunners=\(localRunners.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })")
#endif
        }
        let installPathMap = buildInstallPathMap(
            scopes: scopesSnapshot,
            localRunners: localRunners
        )

        let enrichedRunners = await fetchAndEnrichRunners(
            scopes: scopesSnapshot,
            localRunners: localRunners,
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

        let snapshotRunners     = enrichedRunners
        let snapshotJobs        = jobResult.display
        let snapshotActions     = groupResult.display
        let snapshotRateLimited = rateLimitSnapshot.isLimited
        let snapshotResetDate   = rateLimitSnapshot.resetDate

        log("RunnerStore › fetch complete — actions=\(snapshotActions.count) jobs=\(snapshotJobs.count) runners=\(snapshotRunners.count) isRateLimited=\(snapshotRateLimited) rateLimitResetDate=\(String(describing: snapshotResetDate))")

        let vm = viewModel
        await MainActor.run {
            vm.runners         = snapshotRunners
            vm.jobs            = snapshotJobs
            vm.actions         = snapshotActions
            vm.isRateLimited   = snapshotRateLimited
            vm.rateLimitResetDate = snapshotResetDate
            (NSApp.delegate as? AppDelegate)?.updateStatusIcon()
        }
    }

    // MARK: - fetchAndEnrichRunners

    func fetchAndEnrichRunners(
        scopes: [String],
        localRunners: [RunnerModel],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        log("RunnerStore › fetchAndEnrichRunners ENTER — scopes=\(scopes)")

        let configuredScopeSet = Set(scopes)
        var extraOrgScopes: [String] = []
        for localRunner in localRunners {
            guard let urlString = localRunner.gitHubUrl,
                  let url = URL(string: urlString)
            else { continue }
            let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            guard parts.count == 1 else { continue }
            let orgScope = parts[0]
            guard !configuredScopeSet.contains(orgScope),
                  !extraOrgScopes.contains(orgScope)
            else { continue }
            extraOrgScopes.append(orgScope)
            log("RunnerStore › fetchAndEnrichRunners — derived extra org scope '\(orgScope)' from local runner '\(localRunner.runnerName)'")
        }
        if !extraOrgScopes.isEmpty {
            log("RunnerStore › fetchAndEnrichRunners — extra org scopes to fetch: \(extraOrgScopes)")
        }

        var runnersWithScope: [(scope: String, runner: Runner)] = []

        for scope in scopes {
            let fetched = await fetchRunners(for: scope)
            log("RunnerStore › fetchAndEnrichRunners — scope=\(scope) returned \(fetched.count) runner(s)")
            for runner in fetched { runnersWithScope.append((scope: scope, runner: runner)) }
        }
        for orgScope in extraOrgScopes {
            let fetched = await fetchRunners(for: orgScope)
            log("RunnerStore › fetchAndEnrichRunners — orgScope=\(orgScope) returned \(fetched.count) runner(s)")
            for runner in fetched { runnersWithScope.append((scope: orgScope, runner: runner)) }
        }

        log("RunnerStore › fetchAndEnrichRunners — total runners across all scopes: \(runnersWithScope.count)")
#if DEBUG
        log("RunnerStore › fetchAndEnrichRunners — installPathMap.byFullKey=\(installPathMap.byFullKey.keys.sorted()) byName=\(installPathMap.byName.keys.sorted()) byAgentId=\(installPathMap.byAgentId.keys.sorted()) byApiId=\(installPathMap.byApiId.keys.sorted())")
#endif

        var indexed: [(scope: String, runner: Runner)] = runnersWithScope
        for i in indexed.indices where !indexed[i].runner.busy {
            indexed[i].runner = indexed[i].runner.copying(metrics: nil)
        }

        let busyRunners = indexed.filter { $0.runner.busy }
        log("RunnerStore › fetchAndEnrichRunners — \(busyRunners.count) busy runner(s) need installPath lookup")

        await withTaskGroup(of: (Int, RunnerMetrics?).self) { group in
            for (idx, (scope, runner)) in indexed.enumerated() {
                guard runner.busy else { continue }
                let fullKey           = "\(scope)/\(runner.name)"
                let resolvedByApiId   = installPathMap.byApiId[runner.id]
                let resolvedByAgentId = installPathMap.byAgentId[runner.id]
                let resolvedByFull    = installPathMap.byFullKey[fullKey]
                let resolvedByName    = installPathMap.byName[runner.name]
                let installPath       = resolvedByApiId ?? resolvedByAgentId ?? resolvedByFull ?? resolvedByName
#if DEBUG
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) id=\(runner.id) busy=true; byApiId=\(String(describing: resolvedByApiId)) byAgentId=\(String(describing: resolvedByAgentId)) byFullKey=\(String(describing: resolvedByFull)) byName=\(String(describing: resolvedByName)) → resolved=\(String(describing: installPath))")
#endif
                guard let installPath else {
                    log("RunnerStore › ⚠️ fetchAndEnrichRunners — \(runner.name) busy but NO installPath resolved. id=\(runner.id) fullKey=\(fullKey).")
                    continue
                }
                group.addTask {
                    let metrics = await metricsForRunner(installPath: installPath)
#if DEBUG
                    log("RunnerStore › fetchAndEnrichRunners — \(runner.name) metrics=\(String(describing: metrics))")
#endif
                    return (idx, metrics)
                }
            }
            for await (idx, metrics) in group {
                indexed[idx].runner = indexed[idx].runner.copying(metrics: metrics)
            }
        }

        // Write metrics back to LocalRunnerStore for the runner row badge.
        // Only busy runners with a resolved installPath to avoid spurious warnings.
        let metricsUpdates = indexed.filter {
            $0.runner.busy
            && (installPathMap.byApiId[$0.runner.id] != nil
                || installPathMap.byAgentId[$0.runner.id] != nil
                || installPathMap.byName[$0.runner.name] != nil)
        }
        if !metricsUpdates.isEmpty {
            await MainActor.run {
                for (_, runner) in metricsUpdates {
#if DEBUG
                    log("RunnerStore › fetchAndEnrichRunners — applyMetrics to LocalRunnerStore: \(runner.name) id=\(runner.id) busy=\(runner.busy) metrics=\(String(describing: runner.metrics))")
#endif
                    localRunnerStore.applyMetrics(
                        runner.metrics,
                        forRunnerId: runner.id,
                        name: runner.name
                    )
                }
            }
        }

        let result = indexed.map(\.runner)
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
