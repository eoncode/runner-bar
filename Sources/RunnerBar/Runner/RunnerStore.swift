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
    /// The shared constant.
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
    private var seenGroupIDs: Set<String> = []

    /// Whether the GitHub API is currently rate-limiting this client.
    private(set) var isRateLimited = false
    /// The exact `Date` at which the current rate-limit window expires; `nil` when not rate-limited.
    private(set) var rateLimitResetDate: Date?

    /// Active structured poll task. Cancelled and replaced on every `start()` call.
    private var pollTask: Task<Void, Never>?

    /// Combine subscription that restarts the poll loop when `pollingInterval` changes.
    private var intervalCancellable: AnyCancellable?
    /// Combine subscription that restarts the poll loop when active scopes change.
    private var scopeCancellable: AnyCancellable?

    /// Emits whenever a fetch cycle completes and the store's state has been updated.
    let didUpdate = PassthroughSubject<Void, Never>()

    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == .online || $0.status == .busy }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

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
                } catch {
                    // Task.sleep throws CancellationError when the task is cancelled.
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

    func fetch() async {
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

        // Run heavy network work off the main actor.
        let (enrichedRunners, jobResult, groupResult) = await Task.detached(priority: .background) { [weak self] in
            guard let self else {
                return ([Runner](), JobPollResult.empty, GroupPollResult.empty)
            }
            let enrichedRunners = await self.fetchAndEnrichRunners(
                scopes: scopesSnapshot,
                installPathMap: installPathMap
            )
            let jobResult = await self.buildJobState(snapPrev: snapPrev, snapCache: snapCache)
            let groupResult = await self.buildGroupState(
                snapPrevGroups: snapPrevGroups,
                snapGroupCache: snapGroupCache,
                snapSeenGroupIDs: snapSeenGroupIDs,
                jobCache: jobResult.newCache
            )
            return (enrichedRunners, jobResult, groupResult)
        }.value

        applyFetchResult(
            enrichedRunners: enrichedRunners,
            jobResult: jobResult,
            groupResult: groupResult
        )
    }

    // MARK: - InstallPathMap

    struct InstallPathMap {
        let byFullKey: [String: String]
        let byName: [String: String]
        let byId: [Int: String]
    }

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
        var result: [Runner] = []
        for (scope, var runner) in runnersWithScope {
            guard runner.busy else {
                runner.metrics = nil
                result.append(runner)
                continue
            }
            let fullKey = "\(scope)/\(runner.name)"
            if let installPath = installPathMap.byId[runner.id] {
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) metrics via id=\(runner.id)")
            } else if let installPath = installPathMap.byFullKey[fullKey] {
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) metrics via fullKey=\(fullKey)")
            } else if let installPath = installPathMap.byName[runner.name] {
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — ⚠️ \(runner.name) name-only fallback")
            } else {
                runner.metrics = nil
            }
            result.append(runner)
        }
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}

// MARK: - Empty sentinels

extension JobPollResult {
    static let empty = JobPollResult(display: [], newCache: [:], newPrevLive: [:])
}

extension GroupPollResult {
    static let empty = GroupPollResult(
        display: [],
        newGroupCache: [:],
        newPrevLiveGroups: [:],
        newSeenGroupIDs: []
    )
}
