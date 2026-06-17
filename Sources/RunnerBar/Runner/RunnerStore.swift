// RunnerStore.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - Protocols

/// Protocol that abstracts the polling-interval preference, allowing test doubles
/// to be injected into `RunnerStore` without going through the live singleton.
///
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures without triggering
/// Swift 6's non-Sendable-type-exits-actor-isolated-context error.
///
/// - Note: Test doubles that implement this protocol with mutable state (e.g.
///   `var pollingInterval: Int`) must declare `@unchecked Sendable` to satisfy
///   the compiler under `-strict-concurrency=complete`. The `@MainActor`
///   isolation on the protocol guarantees all access happens on the main actor,
///   making `@unchecked` safe in practice for simple fake classes.
///
/// - Important: Conforming types **must** be `@Observable`. `RunnerStore` wires
///   change notifications via `withObservationTracking`, which only fires its
///   `onChange` callback for properties accessed on concrete `@Observable` types.
///   A plain class conformance compiles correctly but the `onChange` closure will
///   never fire, so the poll loop will silently not restart when `pollingInterval`
///   changes. Annotate all test doubles with `@Observable` to preserve production
///   behaviour.
@MainActor
protocol AppPreferencesStoreProtocol: AnyObject, Sendable {
    /// The current polling interval, in seconds, as configured by the user.
    var pollingInterval: Int { get }
}

/// Conforms `AppPreferencesStore` to `AppPreferencesStoreProtocol` so the live
/// singleton can be injected at the production call site without any wrapper.
extension AppPreferencesStore: AppPreferencesStoreProtocol {}

/// Protocol that abstracts the active-scopes store, allowing test doubles
/// to be injected into `RunnerStore` without going through the live singleton.
///
/// `Sendable` conformance is required so the existential can be captured by the
/// actor and read inside `await MainActor.run { }` closures without triggering
/// Swift 6's non-Sendable-type-exits-actor-isolated-context error.
///
/// - Note: Test doubles that implement this protocol with mutable state (e.g.
///   `var activeScopes: [String]`) must declare `@unchecked Sendable` to satisfy
///   the compiler under `-strict-concurrency=complete`. The `@MainActor`
///   isolation on the protocol guarantees all access happens on the main actor,
///   making `@unchecked` safe in practice for simple fake classes.
///
/// - Important: Conforming types **must** be `@Observable`. `RunnerStore` wires
///   change notifications via `withObservationTracking`, which only fires its
///   `onChange` callback for properties accessed on concrete `@Observable` types.
///   A plain class conformance compiles correctly but the `onChange` closure will
///   never fire, so the poll loop will silently not restart when `activeScopes`
///   changes. Annotate all test doubles with `@Observable` to preserve production
///   behaviour.
@MainActor
protocol ScopeStoreProtocol: AnyObject, Sendable {
    /// The list of scope identifiers (org or repo slugs) currently active.
    var activeScopes: [String] { get }
}

/// Conforms `ScopeStore` to `ScopeStoreProtocol` so the live singleton can be
/// injected at the production call site without any wrapper.
extension ScopeStore: ScopeStoreProtocol {}

// MARK: - Observation helpers

/// Drives a recursive `withObservationTracking` loop for `AppPreferencesStoreProtocol.pollingInterval`
/// entirely on the `@MainActor`. Because every method is `@MainActor`-isolated, the local
/// `func observe()` inside `start()` is implicitly `@MainActor` — no `@Sendable` annotation
/// is required and no value crosses an isolation boundary.
@MainActor
private final class PreferencesObserver {
    /// The continuation used to push new `pollingInterval` values into the `AsyncStream`.
    private let continuation: AsyncStream<Int>.Continuation
    /// The injected preferences store — avoids singleton access inside the observer.
    private let store: any AppPreferencesStoreProtocol

    /// Creates a new observer that writes changes into `continuation`.
    init(continuation: AsyncStream<Int>.Continuation, store: any AppPreferencesStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    /// Registers a single `withObservationTracking` pass and re-registers itself on change.
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
    /// The continuation used to push new `activeScopes` values into the `AsyncStream`.
    private let continuation: AsyncStream<[String]>.Continuation
    /// The injected scope store — avoids singleton access inside the observer.
    private let store: any ScopeStoreProtocol

    /// Creates a new observer that writes changes into `continuation`.
    init(continuation: AsyncStream<[String]>.Continuation, store: any ScopeStoreProtocol) {
        self.continuation = continuation
        self.store = store
    }

    /// Registers a single `withObservationTracking` pass and re-registers itself on change.
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
///   values; any read of their properties must happen inside `await MainActor.run { }`.
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
    /// Assigned in `applyFetchResult` and mirrored to `RunnerViewModel`;
    /// consumed externally via the view model. periphery:ignore
    private(set) var rateLimitResetDate: Date?

    /// Active structured poll task. Cancelled and replaced on every `start()` call.
    private var pollTask: Task<Void, Never>?
    /// Observation task that restarts the poll loop when `pollingInterval` changes.
    /// The `Task` handle is assigned synchronously in `startObservingPreferences` —
    /// in the calling function body, before the task's async work runs — so `deinit`
    /// always cancels a real `Task` value rather than `nil`, even if the actor is
    /// deallocated immediately after `init`.
    private var intervalObservationTask: Task<Void, Never>?
    /// Observation task that restarts the poll loop when active scopes change.
    /// The `Task` handle is assigned synchronously in `startObservingScopes` —
    /// in the calling function body, before the task's async work runs — so `deinit`
    /// always cancels a real `Task` value rather than `nil`, even if the actor is
    /// deallocated immediately after `init`.
    private var scopeObservationTask: Task<Void, Never>?

    /// The view model this store pushes updates into.
    private let viewModel: RunnerViewModel
    /// Injected reference to the local runner store — avoids singleton cross-references
    /// inside the actor body (Swift 6 / PR #1303 requirement).
    private let localRunnerStore: LocalRunnerStore
    /// Injected preferences store. Provides `pollingInterval`.
    /// Pass `AppPreferencesStore.shared` in production; inject a test double in unit tests.
    private let preferencesStore: any AppPreferencesStoreProtocol
    /// Injected scope store. Provides `activeScopes`.
    /// Pass `ScopeStore.shared` in production; inject a test double in unit tests.
    private let scopeStore: any ScopeStoreProtocol
    /// Called on the main actor at the end of every fetch cycle to refresh the status-bar
    /// icon. Injected at init to avoid accessing `NSApp.delegate` from inside the actor
    /// body (PR Principle #4: no singleton access inside actor bodies).
    private let onStatusUpdate: @MainActor @Sendable () -> Void

    // MARK: - Aggregate status

    /// The combined health status across all runners, derived from the current `runners` array.
    /// Read by external consumers (e.g. `AppDelegate`) outside this file's analysis scope.
    /// periphery:ignore
    var aggregateStatus: AggregateStatus { AggregateStatus(runners: runners) }

    // MARK: - Init

    /// Designated init for dependency injection.
    ///
    /// `preferencesStore` and `scopeStore` have no default values because their
    /// concrete `.shared` accessors are `@MainActor`-isolated, and Swift 6 forbids
    /// `@MainActor`-isolated default values in a nonisolated (actor) init context.
    /// Pass `AppPreferencesStore.shared` and `ScopeStore.shared` at the production
    /// call site in `AppDelegate+PanelSetup.swift`, where the caller is already on
    /// the `@MainActor`.
    ///
    /// - Parameters:
    ///   - viewModel: The view model this store pushes UI state into.
    ///   - localRunnerStore: The local runner store used for metrics write-back.
    ///   - preferencesStore: Provides `pollingInterval`. Pass `AppPreferencesStore.shared`
    ///     in production; inject a test double in unit tests.
    ///   - scopeStore: Provides `activeScopes`. Pass `ScopeStore.shared` in production;
    ///     inject a test double in unit tests.
    ///   - onStatusUpdate: Closure called on the main actor after every fetch cycle
    ///     to update the status-bar icon. Typically `{ [weak self] in self?.updateStatusIcon() }`
    ///     — injected here so the actor body never touches `NSApp.delegate`.
    ///
    /// - Note: Swift 6 actor `init` is nonisolated. The observation task `Task` handles
    ///   are assigned synchronously inside `startObservingPreferences` /
    ///   `startObservingScopes` (in the calling function body, before any suspension in
    ///   the task's async work). This means `deinit` always holds real `Task` values by
    ///   the time any suspension occurs, even if the actor is deallocated immediately after
    ///   `init`.
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
        Task { await self.startObservingPreferences() }
        Task { await self.startObservingScopes() }
    }

    // MARK: - Deinit

    deinit {
        pollTask?.cancel()
        intervalObservationTask?.cancel()
        scopeObservationTask?.cancel()
    }

    // MARK: - Observation helpers

    /// Starts (or restarts) the `pollingInterval` observation loop.
    ///
    /// `intervalObservationTask` is assigned synchronously in this function body —
    /// before the task's async work runs — so `deinit` always cancels a real `Task`
    /// rather than a `nil` optional, even if the actor is deallocated immediately
    /// after `init`.
    ///
    /// `AsyncStream.makeStream` returns the stream and a separate continuation value.
    /// The continuation is handed to `PreferencesObserver`, a `@MainActor` class that
    /// owns the recursive `withObservationTracking` registration entirely on the main
    /// actor. The observer is returned from `MainActor.run` and held in the Task's
    /// async scope so it stays alive for the full lifetime of the stream — without
    /// this, `[weak self]` in `onChange` would find `self == nil` on the first change
    /// and silently stop all future polling-interval updates.
    private func startObservingPreferences() {
        intervalObservationTask?.cancel()
        let injectedStore = preferencesStore
        intervalObservationTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            let observer: PreferencesObserver = await MainActor.run {
                let preferencesObserver = PreferencesObserver(continuation: continuation, store: injectedStore)
                preferencesObserver.start()
                return preferencesObserver
            }
            for await newInterval in stream {
                guard !Task.isCancelled else { break }
                log("RunnerStore › pollingInterval changed to \(newInterval) — restarting poll loop")
                await self?.startObservingPreferences()
                guard !Task.isCancelled else { break }
                await self?.start()
                break
            }
            _ = observer // retain until stream ends — do not remove
        }
    }

    /// Starts (or restarts) the `activeScopes` observation loop.
    ///
    /// `scopeObservationTask` is assigned synchronously in this function body —
    /// before the task's async work runs — so `deinit` always cancels a real `Task`
    /// rather than a `nil` optional, even if the actor is deallocated immediately
    /// after `init`.
    ///
    /// Same approach as `startObservingPreferences` — see that method's
    /// doc-comment for the full rationale, including why the observer must be
    /// retained in the Task's async scope beyond the `MainActor.run` closure.
    private func startObservingScopes() {
        scopeObservationTask?.cancel()
        let injectedStore = scopeStore
        scopeObservationTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<[String]>.makeStream()
            let observer: ScopesObserver = await MainActor.run {
                let scopesObserver = ScopesObserver(continuation: continuation, store: injectedStore)
                scopesObserver.start()
                return scopesObserver
            }
            for await _ in stream {
                guard !Task.isCancelled else { break }
                log("RunnerStore › ScopeStore.activeScopes changed — restarting fetch")
                await self?.startObservingScopes()
                guard !Task.isCancelled else { break }
                await self?.start()
                break
            }
            _ = observer // retain until stream ends — do not remove
        }
    }

    // MARK: - Poll loop

    /// Starts (or restarts) the structured async poll loop.
    ///
    /// Safe to call multiple times — the previous task is always cancelled first.
    /// `async` because it reads `@MainActor`-isolated properties via `await MainActor.run { }`.
    /// All callers already wrap this in `Task { await ... }` or `await self?.start()`.
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

    /// Computes the delay before the next poll: 10 s while jobs/actions are active,
    /// otherwise the user's configured idle interval (clamped to ≥ 10 s). Also widened
    /// to the idle interval while rate-limited.
    ///
    /// `async` because it reads `preferencesStore.pollingInterval` which is
    /// `@MainActor`-isolated; uses `await MainActor.run { }` consistently with `fetch()`.
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

    /// Performs one full poll cycle: snapshots active scopes and local runners,
    /// fetches and enriches runners/jobs/action groups, then applies the result
    /// to actor state and pushes it to `RunnerViewModel`.
    func fetch() async {
        await clearGhRateLimit()

        let scopesSnapshot = await MainActor.run { scopeStore.activeScopes }
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY")
        }

        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache
        let snapSeenGroupIDs = seenGroupIDs
        let localRunners = await MainActor.run { viewModel.localRunners }
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

    /// Merges a completed fetch into actor state (runners, jobs, action groups, rate-limit)
    /// and pushes the resulting snapshot to `RunnerViewModel` on the main actor.
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
        log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) runners=\(enrichedRunners.count) isRateLimited=\(rateLimitSnapshot.isLimited) rateLimitResetDate=\(String(describing: rateLimitSnapshot.resetDate))")

        let statusUpdate = onStatusUpdate
        await MainActor.run { [viewModel] in
            viewModel.runners = enrichedRunners
            viewModel.jobs = jobResult.display
            viewModel.actions = groupResult.display
            viewModel.isRateLimited = rateLimitSnapshot.isLimited
            viewModel.rateLimitResetDate = rateLimitSnapshot.resetDate
            statusUpdate()
        }
    }

    // MARK: - fetchAndEnrichRunners

    /// Fetches runners for the given scopes, resolves install paths, and enriches each
    /// runner with live metrics. Writes busy-runner metrics back to `LocalRunnerStore`
    /// and returns the enriched runner list.
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
        // swiftlint:disable:next line_length
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
                let fullKey = "\(scope)/\(runner.name)"
                let resolvedByApiId = installPathMap.byApiId[runner.id]
                let resolvedByAgentId = installPathMap.byAgentId[runner.id]
                let resolvedByFull = installPathMap.byFullKey[fullKey]
                let resolvedByName = installPathMap.byName[runner.name]
                let installPath = resolvedByApiId ?? resolvedByAgentId ?? resolvedByFull ?? resolvedByName
                #if DEBUG
                // swiftlint:disable:next line_length
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
