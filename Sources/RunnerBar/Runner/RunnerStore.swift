// RunnerStore.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - Protocols

/// Protocol that abstracts the polling-interval preference, allowing test doubles
/// to be injected into `RunnerStore` without going through the live singleton.
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures.
@MainActor
protocol AppPreferencesStoreProtocol: AnyObject, Sendable {
    var pollingInterval: Int { get }
}

extension AppPreferencesStore: AppPreferencesStoreProtocol {}

/// Protocol that abstracts the active-scopes store, allowing test doubles
/// to be injected into `RunnerStore` without going through the live singleton.
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures.
@MainActor
protocol ScopeStoreProtocol: AnyObject, Sendable {
    var activeScopes: [String] { get }
}

extension ScopeStore: ScopeStoreProtocol {}

// MARK: - Observation helpers

/// Drives a recursive `withObservationTracking` loop for `AppPreferencesStoreProtocol.pollingInterval`
/// entirely on the `@MainActor`. Because every method is `@MainActor`-isolated, the local
/// `func observe()` inside `start()` is implicitly `@MainActor` — no `@Sendable` annotation
/// is required and no value crosses an isolation boundary.
@MainActor
private final class PreferencesObserver {
    private let continuation: AsyncStream<Int>.Continuation
    private let store: any AppPreferencesStoreProtocol

    init(continuation: AsyncStream<Int>.Continuation, store: any AppPreferencesStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    func start() {
        func observe() {
            withObservationTracking {
                _ = store.pollingInterval
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.continuation.yield(self.store.pollingInterval)
                    self.start()
                }
            }
        }
        observe()
    }
}

/// Drives a recursive `withObservationTracking` loop for `ScopeStoreProtocol.activeScopes`
/// entirely on the `@MainActor`. Same isolation rationale as `PreferencesObserver`.
@MainActor
private final class ScopesObserver {
    private let continuation: AsyncStream<[String]>.Continuation
    private let store: any ScopeStoreProtocol

    init(continuation: AsyncStream<[String]>.Continuation, store: any ScopeStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    func start() {
        func observe() {
            withObservationTracking {
                _ = store.activeScopes
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.continuation.yield(self.store.activeScopes)
                    self.start()
                }
            }
        }
        observe()
    }
}

// MARK: - RunnerStore

/// Swift 6 actor that owns the GitHub poll loop and all derived runner/job/action state.
///
/// **Concurrency model**
/// - The actor runs on its own executor (background thread).
/// - `preferencesStore` and `scopeStore` are `@MainActor`-isolated `Sendable` protocol
///   values; reads must happen inside `await MainActor.run { }`.
/// - After every fetch cycle, results are pushed to the injected `RunnerViewModel` on the
///   main actor via `await MainActor.run { }`. SwiftUI's `@Observable` machinery
///   picks up the mutation automatically — no Combine `PassthroughSubject` needed.
/// - `LocalRunnerStore` is an `actor`; its state is read via the main-actor snapshot
///   pushed to `RunnerViewModel`, not by crossing the actor boundary synchronously.
/// - Status-icon refresh is triggered via the injected `onStatusUpdate` callback rather
///   than accessing `NSApp.delegate` directly (PR Principle #4: no singleton access
///   inside actor bodies).
actor RunnerStore {

    // MARK: - State

    private(set) var runners: [Runner] = []
    private(set) var jobs: [ActiveJob] = []
    private(set) var actions: [WorkflowActionGroup] = []

    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]
    private var prevLiveGroups: [String: WorkflowActionGroup] = [:]
    private var actionGroupCache: [String: WorkflowActionGroup] = [:]
    private var seenGroupIDs: Set<String> = []

    private(set) var isRateLimited = false
    /// periphery:ignore
    private(set) var rateLimitResetDate: Date?

    private var pollTask: Task<Void, Never>?
    private var intervalObservationTask: Task<Void, Never>?
    private var scopeObservationTask: Task<Void, Never>?

    private let viewModel: RunnerViewModel
    private let localRunnerStore: LocalRunnerStore
    /// Injected preferences store — provides `pollingInterval`.
    /// Pass `AppPreferencesStore.shared` in production; inject a test double in unit tests.
    private let preferencesStore: any AppPreferencesStoreProtocol
    /// Injected scope store — provides `activeScopes`.
    /// Pass `ScopeStore.shared` in production; inject a test double in unit tests.
    private let scopeStore: any ScopeStoreProtocol
    private let onStatusUpdate: @MainActor @Sendable () -> Void

    // MARK: - Aggregate status

    /// periphery:ignore
    var aggregateStatus: AggregateStatus { AggregateStatus(runners: runners) }

    // MARK: - Init

    /// Designated init for dependency injection.
    ///
    /// `preferencesStore` and `scopeStore` have no default values because their
    /// concrete `.shared` accessors are `@MainActor`-isolated, and Swift 6 forbids
    /// `@MainActor`-isolated default values in a nonisolated (actor) init.
    /// Pass `AppPreferencesStore.shared` and `ScopeStore.shared` at every production
    /// call site (see `AppDelegate+PanelSetup.swift`).
    ///
    /// - Parameters:
    ///   - viewModel: The view model this store pushes UI state into.
    ///   - localRunnerStore: The local runner store used for metrics write-back.
    ///   - preferencesStore: Provides `pollingInterval`. Use `AppPreferencesStore.shared`
    ///     in production; inject a `FakeAppPreferencesStore` in tests.
    ///   - scopeStore: Provides `activeScopes`. Use `ScopeStore.shared` in production;
    ///     inject a `FakeScopeStore` in tests.
    ///   - onStatusUpdate: Closure called on the main actor after every fetch cycle.
    init(
        viewModel: RunnerViewModel,
        localRunnerStore: LocalRunnerStore,
        preferencesStore: any AppPreferencesStoreProtocol,
        scopeStore: any ScopeStoreProtocol,
        onStatusUpdate: @escaping @MainActor @Sendable () -> Void
    ) {
        self.viewModel = viewModel
        self.localRunnerStore = localRunnerStore
        self.preferencesStore = preferencesStore
        self.scopeStore = scopeStore
        self.onStatusUpdate = onStatusUpdate
        Task { await self._startObservingPreferences() }
        Task { await self._startObservingScopes() }
    }

    // MARK: - Deinit

    deinit {
        pollTask?.cancel()
        intervalObservationTask?.cancel()
        scopeObservationTask?.cancel()
    }

    // MARK: - Observation helpers

    private func _startObservingPreferences() {
        let injectedStore = preferencesStore
        intervalObservationTask?.cancel()
        intervalObservationTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            let observer: PreferencesObserver = await MainActor.run {
                let o = PreferencesObserver(continuation: continuation, store: injectedStore)
                o.start()
                return o
            }
            for await newInterval in stream {
                guard !Task.isCancelled else { break }
                log("RunnerStore › pollingInterval changed to \(newInterval) — restarting poll loop")
                await self?.start()
            }
            _ = observer
        }
    }

    private func _startObservingScopes() {
        let injectedStore = scopeStore
        scopeObservationTask?.cancel()
        scopeObservationTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<[String]>.makeStream()
            let observer: ScopesObserver = await MainActor.run {
                let o = ScopesObserver(continuation: continuation, store: injectedStore)
                o.start()
                return o
            }
            for await _ in stream {
                guard !Task.isCancelled else { break }
                log("RunnerStore › ScopeStore.activeScopes changed — restarting fetch")
                await self?.start()
            }
            _ = observer
        }
    }

    // MARK: - Poll loop

    func start() async {
        let scopes = await MainActor.run { scopeStore.activeScopes }
        log("RunnerStore › start — activeScopes=\(scopes)")
        if scopes.isEmpty {
            log("RunnerStore › ⚠️ start called but activeScopes is EMPTY — actions will not load")
        }
        let localCount = await MainActor.run { viewModel.localRunners.count }
        log("RunnerStore › start — localRunners.count=\(localCount) at start() time")
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

    private func nextPollInterval() async -> TimeInterval {
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions = actions.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, await MainActor.run { preferencesStore.pollingInterval })
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle)")
        return interval
    }

    // MARK: - Fetch

    func fetch() async {
        await clearGhRateLimit()

        let scopesSnapshot = await MainActor.run { scopeStore.activeScopes }
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY")
        }

        let snapPrev         = prevLiveJobs
        let snapCache        = completedCache
        let snapPrevGroups   = prevLiveGroups
        let snapGroupCache   = actionGroupCache
        let snapSeenGroupIDs = seenGroupIDs
        let localRunners     = await MainActor.run { viewModel.localRunners }
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

        log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) runners=\(enrichedRunners.count) isRateLimited=\(rateLimitSnapshot.isLimited) rateLimitResetDate=\(String(describing: rateLimitSnapshot.resetDate))")

        let statusUpdate = onStatusUpdate
        await MainActor.run { [viewModel] in
            viewModel.runners            = enrichedRunners
            viewModel.jobs               = jobResult.display
            viewModel.actions            = groupResult.display
            viewModel.isRateLimited      = rateLimitSnapshot.isLimited
            viewModel.rateLimitResetDate = rateLimitSnapshot.resetDate
            statusUpdate()
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

        let metricsUpdates = indexed.filter {
            $0.runner.busy
            && (installPathMap.byApiId[$0.runner.id] != nil
                || installPathMap.byAgentId[$0.runner.id] != nil
                || installPathMap.byName[$0.runner.name] != nil)
        }
        if !metricsUpdates.isEmpty {
            for (_, runner) in metricsUpdates {
#if DEBUG
                log("RunnerStore › fetchAndEnrichRunners — applyMetrics to LocalRunnerStore: \(runner.name) id=\(runner.id) busy=\(runner.busy) metrics=\(String(describing: runner.metrics))")
#endif
                await localRunnerStore.applyMetrics(
                    runner.metrics,
                    forRunnerId: runner.id,
                    name: runner.name
                )
            }
        }

        let result = indexed.map(\.runner)
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
