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
    /// The timer property.
    private var timer: Timer?
    /// The intervalCancellable property.
    private var intervalCancellable: AnyCancellable?
    /// The scopeCancellable property.
    private var scopeCancellable: AnyCancellable?

    /// Emits whenever a fetch cycle completes and the store's state has been updated.
    let didUpdate = PassthroughSubject<Void, Never>()

    /// The aggregateStatus property.
    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == "online" }.count
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
            DispatchQueue.main.async {
                self?.fetch()
            }
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
        let (installPathByName, installPathByRunnerName) = buildInstallPathMap(
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
                installPathByName: installPathByName,
                installPathByRunnerName: installPathByRunnerName
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

    /// Builds two lookup maps from the local runner list:
    /// - Primary:   "scope/runnerName" → installPath  (exact scope-prefixed match)
    /// - Secondary: "runnerName"        → installPath  (name-only fallback for org-scoped runners
    ///              whose ScopeStore scope string differs from the fetch-time scope key)
    ///
    /// The name-only map is used as a fallback in fetchAndEnrichRunners when the
    /// scope-prefixed key produces no match, preventing silent metrics loss when
    /// scope strings are org-level vs repo-level.
    private func buildInstallPathMap(
        scopes: [String],
        localRunners: [RunnerModel]
    ) -> (byFullKey: [String: String], byName: [String: String]) {
        var byFullKey: [String: String] = [:]
        var byName: [String: String] = [:]
        for localRunner in localRunners {
            guard let path = localRunner.installPath else { continue }
            // Name-only entry — always populated regardless of scope.
            byName[localRunner.runnerName] = path
            // Scope-prefixed entries — one per active scope.
            for scope in scopes {
                byFullKey["\(scope)/\(localRunner.runnerName)"] = path
            }
        }
        log("RunnerStore › buildInstallPathMap — fullKeys=\(byFullKey.keys.sorted()) nameKeys=\(byName.keys.sorted())")
        // Warn early if scopes are empty or no runners are registered — the
        // full-key map will always be empty and metrics will never be assigned.
        if byFullKey.isEmpty && !localRunners.isEmpty {
            log("RunnerStore › ⚠️ buildInstallPathMap — fullKey map is EMPTY (scopes=\(scopes), localRunners=\(localRunners.count)) — check ScopeStore alignment")
        }
        return (byFullKey, byName)
    }

    /// Performs the applyFetchResult operation.
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
        log("RunnerStore › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) isRateLimited=\(ghIsRateLimited)")
        didUpdate.send()
        scheduleTimer(liveActions: groupResult.newPrevLiveGroups.map { $0.value })
    }

    /// Performs the fetchAndEnrichRunners operation.
    nonisolated func fetchAndEnrichRunners(
        scopes: [String],
        installPathByName: [String: String],
        installPathByRunnerName: [String: String]
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
        log("RunnerStore › fetchAndEnrichRunners — installPathByName keys=\(installPathByName.keys.sorted())")
        var result: [Runner] = []
        for (scope, var runner) in runnersWithScope {
            guard runner.busy else {
                runner.metrics = nil
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) is idle, metrics=nil")
                result.append(runner)
                continue
            }
            let fullKey = "\(scope)/\(runner.name)"
            if let installPath = installPathByName[fullKey] {
                // Primary match: scope-prefixed key aligned correctly.
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) metrics via fullKey=\(fullKey)")
            } else if let installPath = installPathByRunnerName[runner.name] {
                // Fallback: scope key didn't match (e.g. org scope vs repo scope string).
                // Use name-only lookup so metrics are not silently lost.
                runner.metrics = metricsForRunner(installPath: installPath)
                log("RunnerStore › fetchAndEnrichRunners — ⚠️ \(runner.name) (scope=\(scope)) fullKey miss, used name-only fallback — check ScopeStore scope strings align with fetch scope")
            } else {
                // No match in either map — runner is not registered locally.
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) busy but no installPath for key=\(fullKey), metrics=nil")
                runner.metrics = nil
            }
            result.append(runner)
        }
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
