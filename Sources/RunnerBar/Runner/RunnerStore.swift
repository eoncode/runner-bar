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
    /// header value).  Sourced from `RateLimitActor.snapshot()` in
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
    /// `LocalRunnerStore` is seeded once at startup (before `start()` is called in
    /// `AppDelegate+PanelSetup`) and kept current reactively via its own `$runners`
    /// Combine sink. There is no need to call `refresh()` here — doing so would
    /// duplicate the `GET /actions/runners` GitHub API call that `fetchAndEnrichRunners`
    /// already makes in the same cycle, doubling the API request rate on the hot path.
    func fetch() async {
        // Reset rate-limit flag at the top of each cycle so that a previous 403
        // does not permanently suppress fetches after the window has expired via the
        // actor's internal reset task. The actor's `clear()` is idempotent.
        await clearGhRateLimit()

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
        let localRunners     = LocalRunnerStore.shared.runners
        log("RunnerStore › fetch — localRunners.count=\(localRunners.count) (used for installPathMap)")
        if localRunners.isEmpty {
            log("RunnerStore › ⚠️ fetch — localRunners is EMPTY; installPathMap will be empty; busy runners will have no metrics this cycle")
        } else {
#if DEBUG
            log("RunnerStore › fetch — localRunners=\(localRunners.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })")
#endif
        }
        let installPathMap   = buildInstallPathMap(
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

    // MARK: - InstallPathMap

    /// Lookup maps built from the local runner list, used by `fetchAndEnrichRunners`.
    struct InstallPathMap {
        /// "scope/runnerName" → installPath  (exact scope-prefixed match)
        let byFullKey: [String: String]
        /// "runnerName" → installPath  (name-only fallback)
        let byName: [String: String]
        /// agentId (Int) → installPath  (local `.runner` JSON AgentId, scope-agnostic)
        let byId: [Int: String]
        /// apiId (Int) → installPath  (GitHub REST API runner id from last enrichment cycle)
        ///
        /// For org runners the GitHub API assigns an `id` that differs from the local
        /// `.runner` JSON `AgentId`. This map is keyed on the API id so that metrics
        /// can be resolved for org runners even when `byId` misses.
        let byApiId: [Int: String]
    }

    /// Builds four lookup maps from the local runner list.
    private func buildInstallPathMap(
        scopes: [String],
        localRunners: [RunnerModel]
    ) -> InstallPathMap {
        var byFullKey: [String: String] = [:]
        var byName: [String: String] = [:]
        var byId: [Int: String] = [:]
        var byApiId: [Int: String] = [:]
        for localRunner in localRunners {
            guard let path = localRunner.installPath else {
                log("RunnerStore › buildInstallPathMap — SKIP \(localRunner.runnerName): installPath is nil")
                continue
            }
            byName[localRunner.runnerName] = path
            if let agentId = localRunner.agentId {
                byId[agentId] = path
            } else {
                log("RunnerStore › buildInstallPathMap — \(localRunner.runnerName): agentId is nil (will rely on apiId/fullKey/name fallback)")
            }
            if let apiId = localRunner.apiId {
                byApiId[apiId] = path
            }
            for scope in scopes {
                byFullKey["\(scope)/\(localRunner.runnerName)"] = path
            }
        }
        log("RunnerStore › buildInstallPathMap — localRunners=\(localRunners.count) scopes=\(scopes) → fullKeys=\(byFullKey.keys.sorted()) nameKeys=\(byName.keys.sorted()) idKeys=\(byId.keys.sorted()) apiIdKeys=\(byApiId.keys.sorted())")
        if byFullKey.isEmpty && !localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — fullKey map is EMPTY despite localRunners=\(localRunners.count). Scopes=\(scopes). Check scope string format alignment with localRunner names.")
        }
        if localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — localRunners is EMPTY. All maps are empty. Busy runners will have no installPath this cycle.")
        }
        return InstallPathMap(byFullKey: byFullKey, byName: byName, byId: byId, byApiId: byApiId)
    }

    // MARK: - Apply result

    /// Commits a completed fetch cycle's results to the store and notifies observers.
    ///
    /// Rate-limit state is read via a single `rateLimitActor.snapshot()` call so that
    /// `isRateLimited` and `rateLimitResetDate` are always consistent with each other.
    /// Using two separate `await`s (`ghIsRateLimited` then a separate reset-date read) would
    /// open a race window where a `clear()` or `set(resetAt:)` arriving between the two
    /// hops could leave the store in an incoherent state (e.g. `isRateLimited == false`
    /// but `rateLimitResetDate != nil`).
    private func applyFetchResult(
        enrichedRunners: [Runner],
        jobResult: JobPollResult,
        groupResult: GroupPollResult
    ) async {
        // Snapshot rate-limit state before any mutation so all store writes are
        // contiguous with no suspension in between — prevents a partial-update
        // window where @MainActor readers see fresh runners against stale rate-limit state.
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
        log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) runners=\(enrichedRunners.count) isRateLimited=\(isRateLimited) rateLimitResetDate=\(String(describing: rateLimitResetDate))")
        didUpdate.send()
    }

    // MARK: - fetchAndEnrichRunners

    /// Fetches runners from GitHub for each scope and enriches busy runners with local CPU/MEM metrics.
    ///
    /// In addition to the user-configured `scopes` (which are always repo-scoped), this
    /// method also fetches from any **org-level** endpoints implied by local runners whose
    /// `gitHubUrl` has a single-component path (e.g. `https://github.com/psw-pwa`).
    /// Without this, org-scoped runners never appear in the fetched list, are never marked
    /// busy, and `metricsForRunner` is never called for them.
    func fetchAndEnrichRunners(
        scopes: [String],
        localRunners: [RunnerModel],
        installPathMap: InstallPathMap
    ) async -> [Runner] {
        log("RunnerStore › fetchAndEnrichRunners ENTER — scopes=\(scopes)")

        // Derive extra org scopes from local runners whose gitHubUrl is org-level
        // (i.e. "https://github.com/orgname" — only one non-empty path component).
        // These are NOT in activeScopes (which only contains repo scopes the user added),
        // so they would never be fetched otherwise — causing org runners to be invisible
        // to the busy-detection and metrics path.
        let configuredScopeSet = Set(scopes)
        var extraOrgScopes: [String] = []
        for localRunner in localRunners {
            guard let urlString = localRunner.gitHubUrl,
                  let url = URL(string: urlString)
            else { continue }
            // Strip leading "/" from path components and filter empties.
            let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            guard parts.count == 1 else { continue }   // org URL has exactly 1 component
            let orgScope = parts[0]                    // e.g. "psw-pwa"
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

        // Fetch configured (repo) scopes
        for scope in scopes {
            let fetched = await fetchRunners(for: scope)
            log("RunnerStore › fetchAndEnrichRunners — scope=\(scope) returned \(fetched.count) runner(s)")
            for runner in fetched {
                runnersWithScope.append((scope: scope, runner: runner))
            }
        }

        // Fetch extra org scopes derived from local runners
        for orgScope in extraOrgScopes {
            let fetched = await fetchRunners(for: orgScope)
            log("RunnerStore › fetchAndEnrichRunners — org scope=\(orgScope) returned \(fetched.count) runner(s)")
            for runner in fetched {
                runnersWithScope.append((scope: orgScope, runner: runner))
            }
        }

        log("RunnerStore › fetchAndEnrichRunners — total runners across all scopes: \(runnersWithScope.count)")
#if DEBUG
        log("RunnerStore › fetchAndEnrichRunners — installPathMap.byFullKey=\(installPathMap.byFullKey.keys.sorted()) byName=\(installPathMap.byName.keys.sorted()) byId=\(installPathMap.byId.keys.sorted()) byApiId=\(installPathMap.byApiId.keys.sorted())")
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
                // Resolution order:
                // 1. byApiId  — GitHub REST API id (populated after first enrichment cycle);
                //               fixes org runners whose agentId ≠ API id.
                // 2. byId     — local .runner JSON AgentId; works for repo runners.
                // 3. byFullKey — scope/name string match.
                // 4. byName   — name-only last resort.
                let resolvedByApiId = installPathMap.byApiId[runner.id]
                let resolvedById    = installPathMap.byId[runner.id]
                let resolvedByFull  = installPathMap.byFullKey[fullKey]
                let resolvedByName  = installPathMap.byName[runner.name]
                let installPath     = resolvedByApiId ?? resolvedById ?? resolvedByFull ?? resolvedByName
#if DEBUG
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) id=\(runner.id) busy=true; fullKey=\(fullKey); byApiId=\(String(describing: resolvedByApiId)) byId=\(String(describing: resolvedById)) byFullKey=\(String(describing: resolvedByFull)) byName=\(String(describing: resolvedByName)) → resolved=\(String(describing: installPath))")
#endif
                guard let installPath else {
                    log("RunnerStore › ⚠️ fetchAndEnrichRunners — \(runner.name) busy but NO installPath resolved. id=\(runner.id) fullKey=\(fullKey). localRunners may be empty or scope/name mismatch.")
                    continue
                }
                group.addTask {
                    let metrics = await metricsForRunner(installPath: installPath)
#if DEBUG
                    log("RunnerStore › fetchAndEnrichRunners — \(runner.name) metrics fetched installPath=\(installPath) metrics=\(String(describing: metrics))")
#endif
                    return (idx, metrics)
                }
            }
            for await (idx, metrics) in group {
                indexed[idx].runner = indexed[idx].runner.copying(metrics: metrics)
            }
        }

        // Write metrics back to LocalRunnerStore so the main-view runner row badge
        // reflects the latest CPU/MEM values. applyMetrics is a lightweight in-place
        // copying(metrics:) — no disk I/O, no API call, no refresh() cycle.
        // Only apply for self-hosted runners (those with a resolved installPath) to
        // avoid spurious ⚠️ warnings for cloud-hosted runners that have no local entry.
        // Only write back for BUSY runners — idle runners have metrics=nil stamped above
        // and writing nil back would stomp the values applyRefreshResults just preserved.
        for (_, runner) in indexed
            where runner.busy
               && (installPathMap.byApiId[runner.id] != nil
                   || installPathMap.byId[runner.id] != nil
                   || installPathMap.byName[runner.name] != nil) {
#if DEBUG
            log("RunnerStore › fetchAndEnrichRunners — applyMetrics to LocalRunnerStore: \(runner.name) id=\(runner.id) busy=\(runner.busy) metrics=\(String(describing: runner.metrics))")
#endif
            LocalRunnerStore.shared.applyMetrics(
                runner.metrics,
                forRunnerId: runner.id,
                name: runner.name
            )
        }

        let result = indexed.map(\.runner)
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
