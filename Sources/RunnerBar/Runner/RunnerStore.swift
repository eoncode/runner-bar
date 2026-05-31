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

    /// Documentation.
    private(set) var runners: [Runner] = []
    /// Documentation.
    private(set) var jobs: [ActiveJob] = []
    /// Documentation.
    private(set) var actions: [WorkflowActionGroup] = []

    /// The prevLiveJobs property.
    private var prevLiveJobs: [Int: ActiveJob] = [:]
    /// The completedCache property.
    private var completedCache: [Int: ActiveJob] = [:]
    /// The prevLiveGroups property.
    private var prevLiveGroups: [String: WorkflowActionGroup] = [:]
    /// The actionGroupCache property.
    private var actionGroupCache: [String: WorkflowActionGroup] = [:]

    /// Documentation.
    private(set) var isRateLimited = false

    /// The exact moment the current rate-limit window expires.
    ///
    /// Set to `nil` when no rate-limit is active or when the reset time is
    /// unknown (e.g. CLI code path that sets `ghIsRateLimited` without a
    /// header value).  Sourced from `ghRateLimitResetDate` in
    /// `applyFetchResult` and propagated via `RunnerViewModel` to the
    /// `rateLimitBanner` in `PanelMainView`.
    private(set) var rateLimitResetDate: Date?

    /// The timer property.
    /// Safety: only mutated on MainActor (scheduleTimer/start). Timer callbacks
    /// re-enter on the main run loop via Task { @MainActor in }, so no concurrent access.
    nonisolated(unsafe) private var timer: Timer?
    /// The intervalCancellable property.
    private var intervalCancellable: AnyCancellable?
    /// The scopeCancellable property.
    private var scopeCancellable: AnyCancellable?

    /// Emits whenever a fetch cycle completes and the store’s state has been updated.
    let didUpdate = PassthroughSubject<Void, Never>()

    /// The aggregateStatus property.
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
                log("RunnerStore › pollingInterval changed to \(newInterval) — rescheduling timer")
                self?.scheduleTimer()
            }
        scopeCancellable = ScopeStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                log("RunnerStore › ScopeStore changed — restarting fetch")
                self?.start()
            }
    }

    /// Performs the start operation.
    func start() {
        let scopes = ScopeStore.shared.activeScopes
        log("RunnerStore › start — activeScopes=\(scopes)")
        if scopes.isEmpty {
            log("RunnerStore › ⚠️ start called but activeScopes is EMPTY — actions will not load")
        }
        timer?.invalidate()
        log("RunnerStore › start — calling fetch()")
        fetch()
    }

    /// Performs the scheduleTimer operation.
    private func scheduleTimer(liveActions: [WorkflowActionGroup]? = nil) {
        timer?.invalidate()
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let actionsToCheck = liveActions ?? self.actions
        let hasActiveActions = actionsToCheck.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, AppPreferencesStore.shared.pollingInterval)
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › scheduleTimer — next poll in \(Int(interval))s (hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle))")
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            log("RunnerStore › timer fired")
            Task { @MainActor [weak self] in self?.fetch() }
        }
    }

    /// Performs the fetch operation.
    func fetch() {
        let scopesSnapshot = ScopeStore.shared.activeScopes
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY")
        }
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache
        let installPathMap = buildInstallPathMap(
            scopes: scopesSnapshot,
            localRunners: LocalRunnerStore.shared.runners
        )

        // Task.detached ensures the body runs off the main actor so that
        // urlSessionAPI's dispatchPrecondition(.notOnQueue(.main)) does not trap.
        // (A plain Task on a @MainActor type inherits the actor and stays on the main thread.)
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            ghIsRateLimited = false
            let enrichedRunners = self.fetchAndEnrichRunners(
                scopes: scopesSnapshot,
                installPathMap: installPathMap
            )
            let jobResult = self.buildJobState(snapPrev: snapPrev, snapCache: snapCache)
            let groupResult = self.buildGroupState(
                snapPrevGroups: snapPrevGroups,
                snapGroupCache: snapGroupCache,
                jobCache: jobResult.newCache
            )
            await MainActor.run {
                self.applyFetchResult(
                    enrichedRunners: enrichedRunners,
                    jobResult: jobResult,
                    groupResult: groupResult
                )
            }
        }
    }

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
    /// The ID map is the most reliable — GitHub writes the runner’s integer ID
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

    /// Applies a completed fetch cycle’s results to the store’s @MainActor state.
    ///
    /// Copies `ghIsRateLimited` and `ghRateLimitResetDate` from the transport
    /// layer so the full rate-limit context (flag + exact reset moment) is
    /// available to `RunnerViewModel` and ultimately to `PanelMainView`’s
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
        isRateLimited = ghIsRateLimited
        // Mirror the reset date so the UI can show an accurate countdown.
        // ghRateLimitResetDate is nil when no rate-limit is active, which
        // correctly clears the countdown when polls resume normally.
        rateLimitResetDate = ghRateLimitResetDate
        log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) isRateLimited=\(ghIsRateLimited) rateLimitResetDate=\(String(describing: rateLimitResetDate))")
        didUpdate.send()
        scheduleTimer(liveActions: groupResult.newPrevLiveGroups.map { $0.value })
    }

    /// Performs the fetchAndEnrichRunners operation.
    nonisolated func fetchAndEnrichRunners(
        scopes: [String],
        installPathMap: InstallPathMap
    ) -> [Runner] {
        log("RunnerStore › fetchAndEnrichRunners ENTER")
        log("RunnerStore › fetchAndEnrichRunners — activeScopes=\(scopes)")
        var runnersWithScope: [(scope: String, runner: Runner)] = []
        for scope in scopes {
            let fetched = fetchRunners(for: scope)
            log("RunnerStore › fetchAndEnrichRunners — scope=\(scope) returned \(fetched.count) runner(s)")
            for runner in fetched {
                runnersWithScope.append((scope: scope, runner: runner))
            }
        }
        log("RunnerStore › fetchAndEnrichRunners — installPathMap.byFullKey keys=\(installPathMap.byFullKey.keys.sorted())")
        var result: [Runner] = []
        for (scope, var runner) in runnersWithScope {
            guard runner.busy else {
                runner.metrics = nil
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) is idle, metrics=nil")
                result.append(runner)
                continue
            }
            let fullKey = "\(scope)/\(runner.name)"
            // Priority: id → fullKey → name → nil
            if let installPath = installPathMap.byId[runner.id] {
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) metrics via id=\(runner.id)")
            } else if let installPath = installPathMap.byFullKey[fullKey] {
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) metrics via fullKey=\(fullKey)")
            } else if let installPath = installPathMap.byName[runner.name] {
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — ⚠️ \(runner.name) (scope=\(scope)) fullKey miss, used name-only fallback")
            } else {
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) busy but no installPath for key=\(fullKey), metrics=nil")
                runner.metrics = nil
            }
            result.append(runner)
        }
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
