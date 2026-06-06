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
                log("RunnerStore › ScopeStore changed — restarting fetch")
                self?.start()
            }
    }

    deinit {
        // Cancel the poll loop when the store is deallocated.
        // RunnerStore is a singleton so this path is never taken at runtime,
        // but the explicit cancel makes lifecycle intent clear and guards
        // against future refactors that move away from a singleton.
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
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Immediate first fetch.
            await self.fetch()
            // Subsequent fetches on a dynamic interval.
            while !Task.isCancelled {
                let interval = self.nextPollInterval()
                log("RunnerStore › poll loop — next fetch in \(Int(interval))s")
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch is CancellationError {
                    // Task was cancelled — exit the loop cleanly.
                    break
                } catch {
                    // Unexpected error — exit to avoid silent infinite loop.
                    break
                }
                guard !Task.isCancelled else { break }
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
        log("RunnerStore › nextPollInterval — \(Int(interval))s (hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle))")
        return interval
    }

    // MARK: - Fetch

    /// Performs one complete poll cycle: fetches runners, jobs, and action groups,
    /// then applies results on the main actor via `applyFetchResult`.
    ///
    /// Each `await` call below suspends off the main actor during its network work
    /// and returns to `@MainActor` automatically — no `Task.detached` wrapper is
    /// needed. A plain `Task { }` on a `@MainActor` type inherits the actor, but
    /// the `await` points release it to the cooperative thread pool for the
    /// duration of each network call.
    /// Priority is inherited from the poll loop Task launched in `start()`.
    func fetch() async {
        // Proactively reset the transport-layer rate-limit flag at the start of each
        // cycle. The transport clears it automatically on a successful 2xx response
        // via clearRateLimitIfNeeded(), but resetting here ensures a stale flag from
        // a previous window cannot linger if the next cycle starts before a 2xx fires.
        ghIsRateLimited = false

        let scopesSnapshot = ScopeStore.shared.activeScopes
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY")
        }
        let snapPrev         = prevLiveJobs
        let snapCache        = completedCache
        let snapPrevGroups   = prevLiveGroups
        let snapGroupCache   = actionGroupCache
        let snapSeenGroupIDs = seenGroupIDs
        let installPathMap   = buildInstallPathMap(
            scopes: scopesSnapshot,
            localRunners: LocalRunnerStore.shared.runners
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

    /// Builds three lookup maps from the local runner list:
    /// - Primary:    "scope/runnerName" → installPath  (exact scope-prefixed match)
    /// - Secondary:  "runnerName"        → installPath  (name-only fallback)
    /// - Tertiary:   agentId (Int)        → installPath  (ID-based, scope-agnostic)
    ///
    /// The ID map is the most reliable — GitHub writes the runner's integer ID
    /// to the `.runner` JSON on disk during `config.sh`, so it is stable across
    /// renames and scope-string format changes.  Runners that predate this field
    /// (agentId == nil) fall through to the fullKey / name maps.
    private func buildInstallPathMap(
        scopes: [String],
        localRunners: [RunnerModel]
    ) -> InstallPathMap {
        var byFullKey: [String: String] = [:]
        var byName: [String: String] = [:]
        var byId: [Int: String] = [:]
        for localRunner in localRunners {
            guard let path = localRunner.installPath else { continue }
            byName[localRunner.runnerName] = path
            if let runnerId = localRunner.agentId {
                byId[runnerId] = path
            }
            for scope in scopes {
                byFullKey["\(scope)/\(localRunner.runnerName)"] = path
            }
        }
        log("RunnerStore › buildInstallPathMap — fullKeys=\(byFullKey.keys.sorted()) nameKeys=\(byName.keys.sorted()) idKeys=\(byId.keys.sorted())")
        if byFullKey.isEmpty && !localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — fullKey map is EMPTY (scopes=\(scopes), localRunners=\(localRunners.count)) — check ScopeStore alignment")
        }
        return InstallPathMap(byFullKey: byFullKey, byName: byName, byId: byId)
    }

    // MARK: - Apply result

    /// Applies a completed fetch cycle's results to the store's @MainActor state.
    ///
    /// Copies `ghIsRateLimited` and `ghRateLimitResetDate` from the transport
    /// layer so the full rate-limit context (flag + exact reset moment) is
    /// available to `RunnerViewModel` and ultimately to `PanelMainView`'s
    /// live-countdown banner.
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
        log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) isRateLimited=\(ghIsRateLimited) rateLimitResetDate=\(String(describing: rateLimitResetDate))")
        didUpdate.send()
    }

    // MARK: - fetchAndEnrichRunners

    /// Fetches the runner list for all active scopes and enriches each entry
    /// with install-path data from the local runner store.
    func fetchAndEnrichRunners(
        scopes: [String],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        log("RunnerStore › fetchAndEnrichRunners ENTER")
        log("RunnerStore › fetchAndEnrichRunners — activeScopes=\(scopes)")
        var runnersWithScope: [(scope: String, runner: Runner)] = []
        for scope in scopes {
            let fetched = await fetchRunners(for: scope)
            log("RunnerStore › fetchAndEnrichRunners — scope=\(scope) returned \(fetched.count) runner(s)")
            for runner in fetched {
                runnersWithScope.append((scope: scope, runner: runner))
            }
        }
        log("RunnerStore › fetchAndEnrichRunners — installPathMap.byFullKey keys=\(installPathMap.byFullKey.keys.sorted())")
        // Resolve install paths and nil-out idle runners first (no async work needed).
        var indexed: [(scope: String, runner: Runner)] = runnersWithScope
        for i in indexed.indices where !indexed[i].runner.busy {
            indexed[i].runner = indexed[i].runner.copying(metrics: nil)
            log("RunnerStore › fetchAndEnrichRunners — \(indexed[i].runner.name) (scope=\(indexed[i].scope)) is idle, metrics=nil")
        }
        // Fetch metrics for all busy runners concurrently. metricsForRunner is now
        // async (uses ProcessRunner.runAsync internally) so no Task.detached needed.
        // Poll latency is bounded by the slowest single runner, not their sum (#1156, #1157).
        await withTaskGroup(of: (Int, RunnerMetrics?).self) { group in
            for (idx, (scope, runner)) in indexed.enumerated() {
                guard runner.busy else { continue }
                let fullKey = "\(scope)/\(runner.name)"
                let installPath = installPathMap.byId[runner.id]
                    ?? installPathMap.byFullKey[fullKey]
                    ?? installPathMap.byName[runner.name]
                guard let installPath else {
                    log("RunnerStore › fetchAndEnrichRunners — \(runner.name) busy but no installPath for key=\(fullKey), metrics=nil")
                    continue
                }
                group.addTask {
                    let metrics = await metricsForRunner(installPath: installPath)
                    log("RunnerStore › fetchAndEnrichRunners — \(runner.name) metrics fetched installPath=\(installPath)")
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
