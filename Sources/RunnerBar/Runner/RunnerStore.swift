// RunnerStore.swift
// RunnerBar
import AppKit
import Combine
import Foundation
import RunnerBarCore

// MARK: - RunnerStore

// swiftlint:disable:next type_body_length
/// Manages RunnerStore state and behaviour.
@MainActor
final class RunnerStore {
    /// The app-wide singleton. Always accessed on the main actor.
    static let shared = RunnerStore()

    /// Live runner list, updated after each poll cycle.
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
    /// IDs of action groups whose failure hook has already been fired.
    ///
    /// Kept separate from `actionGroupCache` so that cache eviction (capped at
    /// `groupCacheLimit = 30`) does not re-arm the hook for old completed groups
    /// that are still present in GitHub's last-100-completed feed.
    private var seenGroupIDs: Set<String> = []

    /// Whether the GitHub API is currently rate-limiting this client.
    private(set) var isRateLimited = false
    /// The exact moment the current rate-limit window expires.
    ///
    /// Set to `nil` when no rate-limit is active or when the reset time is
    /// unknown (e.g. CLI code path that sets `ghIsRateLimited` without a
    /// header value).  Sourced from `ghRateLimitResetDate` in
    /// `applyFetchResult` and propagated via `RunnerViewModel` to the
    /// `rateLimitBanner` in `PanelMainView`.
    private(set) var rateLimitResetDate: Date?

    /// Active structured poll task. Cancelled and replaced on every `start()` call.
    private var pollTask: Task<Void, Never>?

    /// Combine subscription that restarts the poll loop when `pollingInterval` changes.
    private var intervalCancellable: AnyCancellable?
    /// Combine subscription that restarts the poll loop when active scopes change.
    private var scopeCancellable: AnyCancellable?

    /// Emits whenever a fetch cycle completes and the store's state has been updated.
    let didUpdate = PassthroughSubject<Void, Never>()

    /// The aggregate online/offline status across all runners.
    ///
    /// A runner with `.busy` status is connected to GitHub and executing a job,
    /// so it counts toward the online tally alongside `.online` runners.
    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == .online || $0.status == .busy }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

    /// Private initialiser — use `shared`.
    private init() {
        log("RunnerStore › init")
        intervalCancellable = AppPreferencesStore.shared.$pollingInterval
            .dropFirst(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newInterval in
                log("RunnerStore › pollingInterval changed to \(newInterval) — restarting poll loop")
                self?.start()
            }
        scopeCancellable = ScopeStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                log("RunnerStore › ScopeStore.objectWillChange — restarting fetch")
                self?.start()
            }
        log("RunnerStore › init — complete, waiting for start()")
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Poll loop

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
    private func nextPollInterval() -> TimeInterval {
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

    // MARK: - Fetch

    /// Performs one complete poll cycle: fetches runners, jobs, and action groups,
    /// then applies results on the main actor via `applyFetchResult`.
    ///
    /// FIX (#1179): Triggers LocalRunnerStore.shared.refresh() at the top of each
    /// fetch cycle so the installPathMap always reflects the current on-disk state.
    /// This is an async kick-off (not awaited) — refresh() is guarded by isScanning
    /// so concurrent cycles are safe. The refreshed runners will be picked up by
    /// the NEXT fetch cycle if they land after buildInstallPathMap runs this cycle.
    /// On first launch, refresh() was already called before start() in
    /// AppDelegate+PanelSetup, so the first fetch sees a populated localRunners.
    func fetch() async {
        ghIsRateLimited = false

        let scopesSnapshot = ScopeStore.shared.activeScopes
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY")
        }

        // Refresh local runner list so installPathMap stays current.
        // isScanning prevents concurrent refreshes. We kick it off here and
        // read LocalRunnerStore.shared.runners immediately — if a refresh is
        // already in flight from a previous cycle or the startup call, we read
        // whatever was last committed (still correct, just potentially one cycle stale).
        let localCountBefore = LocalRunnerStore.shared.runners.count
        log("RunnerStore › fetch — LocalRunnerStore.shared.runners.count BEFORE refresh kick=\(localCountBefore) isScanning=\(LocalRunnerStore.shared.isScanning)")
        if !LocalRunnerStore.shared.isScanning {
            log("RunnerStore › fetch — kicking LocalRunnerStore.refresh() (not already scanning)")
            LocalRunnerStore.shared.refresh()
        } else {
            log("RunnerStore › fetch — LocalRunnerStore.refresh() already in flight, skipping kick")
        }

        let snapPrev         = prevLiveJobs
        let snapCache        = completedCache
        let snapPrevGroups   = prevLiveGroups
        let snapGroupCache   = actionGroupCache
        let snapSeenGroupIDs = seenGroupIDs
        let localRunners     = LocalRunnerStore.shared.runners
        log("RunnerStore › fetch — localRunners.count=\(localRunners.count) (used for installPathMap)")
        if localRunners.isEmpty {
            log("RunnerStore › ⚠️ fetch — localRunners is EMPTY; installPathMap will be empty; busy runners will have no metrics this cycle")
        } else {
            log("RunnerStore › fetch — localRunners=\(localRunners.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)))" })")
        }
        let installPathMap   = buildInstallPathMap(
            scopes: scopesSnapshot,
            localRunners: localRunners
        )

        let enrichedRunners = await fetchAndEnrichRunners(
            scopes: scopesSnapshot,
            installPathMap: installPathMap
        )
        let jobResult = await buildJobState(snapPrev: snapPrev, snapCache: snapCache)
        let groupResult = await buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            snapSeenGroupIDs: snapSeenGroupIDs,
            jobCache: jobResult.newCache
        )

        applyFetchResult(
            enrichedRunners: enrichedRunners,
            jobResult: jobResult,
            groupResult: groupResult
        )
    }

    // MARK: - InstallPathMap

    /// Lookup maps built from the local runner list, used by `fetchAndEnrichRunners`.
    struct InstallPathMap {
        /// "scope/runnerName" → installPath  (exact scope-prefixed match)
        let byFullKey: [String: String]
        /// "runnerName" → installPath  (name-only fallback)
        let byName: [String: String]
        /// agentId (Int) → installPath  (ID-based, scope-agnostic)
        let byId: [Int: String]
    }

    /// Builds three lookup maps from the local runner list.
    private func buildInstallPathMap(
        scopes: [String],
        localRunners: [RunnerModel]
    ) -> InstallPathMap {
        var byFullKey: [String: String] = [:]
        var byName: [String: String] = [:]
        var byId: [Int: String] = [:]
        for localRunner in localRunners {
            guard let path = localRunner.installPath else {
                log("RunnerStore › buildInstallPathMap — SKIP \(localRunner.runnerName): installPath is nil")
                continue
            }
            byName[localRunner.runnerName] = path
            if let runnerId = localRunner.agentId {
                byId[runnerId] = path
            } else {
                log("RunnerStore › buildInstallPathMap — \(localRunner.runnerName): agentId is nil (will rely on fullKey/name fallback)")
            }
            for scope in scopes {
                byFullKey["\(scope)/\(localRunner.runnerName)"] = path
            }
        }
        log("RunnerStore › buildInstallPathMap — localRunners=\(localRunners.count) scopes=\(scopes) → fullKeys=\(byFullKey.keys.sorted()) nameKeys=\(byName.keys.sorted()) idKeys=\(byId.keys.sorted())")
        if byFullKey.isEmpty && !localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — fullKey map is EMPTY despite localRunners=\(localRunners.count). Scopes=\(scopes). Check scope string format alignment with localRunner names.")
        }
        if localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — localRunners is EMPTY. All maps are empty. Busy runners will have no installPath this cycle.")
        }
        return InstallPathMap(byFullKey: byFullKey, byName: byName, byId: byId)
    }

    // MARK: - Apply result

    private func applyFetchResult(
        enrichedRunners: [Runner],
        jobResult: JobPollResult,
        groupResult: GroupPollResult
    ) {
        runners = enrichedRunners
        jobs = jobResult.display
        completedCache = jobResult.newCache
        prevLiveJobs = jobResult.newPrevLive
        actions = groupResult.display
        actionGroupCache = groupResult.newGroupCache
        prevLiveGroups = groupResult.newPrevLiveGroups
        seenGroupIDs = groupResult.newSeenGroupIDs
        isRateLimited = ghIsRateLimited
        rateLimitResetDate = ghRateLimitResetDate
        log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) runners=\(enrichedRunners.count) isRateLimited=\(ghIsRateLimited) rateLimitResetDate=\(String(describing: rateLimitResetDate))")
        didUpdate.send()
    }

    // MARK: - fetchAndEnrichRunners

    func fetchAndEnrichRunners(
        scopes: [String],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        log("RunnerStore › fetchAndEnrichRunners ENTER — scopes=\(scopes)")
        var runnersWithScope: [(scope: String, runner: Runner)] = []
        for scope in scopes {
            let fetched = await fetchRunners(for: scope)
            log("RunnerStore › fetchAndEnrichRunners — scope=\(scope) returned \(fetched.count) runner(s)")
            for runner in fetched {
                runnersWithScope.append((scope: scope, runner: runner))
            }
        }
        log("RunnerStore › fetchAndEnrichRunners — total runners across all scopes: \(runnersWithScope.count)")
        log("RunnerStore › fetchAndEnrichRunners — installPathMap.byFullKey=\(installPathMap.byFullKey.keys.sorted()) byName=\(installPathMap.byName.keys.sorted()) byId=\(installPathMap.byId.keys.sorted())")

        var indexed: [(scope: String, runner: Runner)] = runnersWithScope
        for i in indexed.indices where !indexed[i].runner.busy {
            indexed[i].runner = indexed[i].runner.copying(metrics: nil)
            log("RunnerStore › fetchAndEnrichRunners — \(indexed[i].runner.name) (scope=\(indexed[i].scope)) is idle, metrics=nil")
        }

        let busyRunners = indexed.filter { $0.runner.busy }
        log("RunnerStore › fetchAndEnrichRunners — \(busyRunners.count) busy runner(s) need installPath lookup")

        await withTaskGroup(of: (Int, RunnerMetrics?).self) { group in
            for (idx, (scope, runner)) in indexed.enumerated() {
                guard runner.busy else { continue }
                let fullKey = "\(scope)/\(runner.name)"
                let resolvedById   = installPathMap.byId[runner.id]
                let resolvedByFull = installPathMap.byFullKey[fullKey]
                let resolvedByName = installPathMap.byName[runner.name]
                let installPath    = resolvedById ?? resolvedByFull ?? resolvedByName
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) id=\(runner.id) busy=true; fullKey=\(fullKey); byId=\(String(describing: resolvedById)) byFullKey=\(String(describing: resolvedByFull)) byName=\(String(describing: resolvedByName)) → resolved=\(String(describing: installPath))")
                guard let installPath else {
                    log("RunnerStore › ⚠️ fetchAndEnrichRunners — \(runner.name) busy but NO installPath resolved. id=\(runner.id) fullKey=\(fullKey). localRunners may be empty or scope/name mismatch.")
                    continue
                }
                group.addTask {
                    let metrics = await metricsForRunner(installPath: installPath)
                    log("RunnerStore › fetchAndEnrichRunners — \(runner.name) metrics fetched installPath=\(installPath) metrics=\(String(describing: metrics))")
                    return (idx, metrics)
                }
            }
            for await (idx, metrics) in group {
                indexed[idx].runner = indexed[idx].runner.copying(metrics: metrics)
            }
        }
        let result = indexed.map(\.runner)
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
