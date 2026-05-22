import AppKit
import Combine
import Foundation

// MARK: - RunnerStore

// swiftlint:disable:next type_body_length
final class RunnerStore {
    static let shared = RunnerStore()

    private(set) var runners: [Runner] = []
    private(set) var jobs: [ActiveJob] = []
    private(set) var actions: [ActionGroup] = []

    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]
    private var prevLiveGroups: [String: ActionGroup] = [:]
    private var actionGroupCache: [String: ActionGroup] = [:]

    private(set) var isRateLimited = false
    private var timer: Timer?
    private var intervalCancellable: AnyCancellable?
    private var scopeCancellable: AnyCancellable?

    /// Emits whenever a fetch cycle completes and the store's state has been updated.
    let didUpdate = PassthroughSubject<Void, Never>()

    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == "online" }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

    private init() {
        log("RunnerStore › init")
        intervalCancellable = SettingsStore.shared.$pollingInterval
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

    @MainActor
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

    private func scheduleTimer(liveActions: [ActionGroup]? = nil) {
        timer?.invalidate()
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let actionsToCheck = liveActions ?? self.actions
        let hasActiveActions = actionsToCheck.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, SettingsStore.shared.pollingInterval)
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › scheduleTimer — next poll in \(Int(interval))s (hasActive=\(hasActive) rateLimited=\(isRateLimited) baseIdle=\(baseIdle))")
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            log("RunnerStore › timer fired — hopping to main then calling fetch()")
            DispatchQueue.main.async {
                self?.fetch()
            }
        }
    }

    /// Always called on the main thread. @MainActor allows reading
    /// LocalRunnerStore.shared.runners without an actor hop.
    @MainActor
    func fetch() {
        let scopesSnapshot = ScopeStore.shared.activeScopes
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY — buildGroupState will produce no actions")
        }
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache

        let installPathByName = buildInstallPathMap(
            scopes: scopesSnapshot,
            localRunners: LocalRunnerStore.shared.runners
        )

        Task.detached(priority: .background) { [weak self] in
            guard let self else {
                log("RunnerStore › fetch background — self is nil, aborting")
                return
            }
            ghIsRateLimited = false
            let enrichedRunners = self.fetchAndEnrichRunners(
                scopes: scopesSnapshot,
                installPathByName: installPathByName
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

    private func buildInstallPathMap(scopes: [String], localRunners: [RunnerModel]) -> [String: String] {
        var map: [String: String] = [:]
        for localRunner in localRunners {
            guard let path = localRunner.installPath else { continue }
            for scope in scopes {
                map["\(scope)/\(localRunner.runnerName)"] = path
            }
        }
        log("RunnerStore › buildInstallPathMap — keys=\(map.keys.sorted())")
        return map
    }

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

    func fetchAndEnrichRunners(scopes: [String], installPathByName: [String: String]) -> [Runner] {
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
            let key = "\(scope)/\(runner.name)"
            guard let installPath = installPathByName[key] else {
                log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) busy but no local installPath for key=\(key), metrics=nil")
                runner.metrics = nil
                result.append(runner)
                continue
            }
            runner.metrics = metricsForRunner(installPath: installPath)
            log("RunnerStore › fetchAndEnrichRunners — \(runner.name) (scope=\(scope)) metrics=\(String(describing: runner.metrics))")
            result.append(runner)
        }
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
