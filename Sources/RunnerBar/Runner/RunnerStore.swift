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
    /// Callers subscribe with `.sink { ... }` and store the returned `AnyCancellable`
    /// to control the subscription lifetime — no manual weak-capture required.
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
        // Restart polling when the global polling interval changes.
        intervalCancellable = SettingsStore.shared.$pollingInterval
            .dropFirst(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newInterval in
                log("RunnerStore › pollingInterval changed to \(newInterval) — rescheduling timer")
                self?.scheduleTimer()
            }
        // Restart polling when any scope's isEnabled flag changes (Phase 4 — #503).
        // dropFirst(1) skips the initial emission on subscription.
        scopeCancellable = ScopeStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                log("RunnerStore › ScopeStore changed — restarting fetch")
                self?.start()
            }
    }

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

    /// Schedule the next poll. Pass `liveActions` to evaluate hasActive against
    /// only the freshly-fetched live groups — NOT the display cache which may
    /// still contain frozen/completed groups and would keep hasActive=true forever.
    private func scheduleTimer(liveActions: [ActionGroup]? = nil) {
        timer?.invalidate()
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        // Use the caller-supplied live snapshot when available; fall back to self.actions
        // only for manual reschedules (e.g. pollingInterval changes) where no fresh data exists.
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
            log("RunnerStore › timer fired — calling fetch()")
            self?.fetch()
        }
    }

    func fetch() {
        // Phase 4 (#503): use activeScopes — disabled scopes are skipped.
        let scopesSnapshot = ScopeStore.shared.activeScopes
        log("RunnerStore › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot) thread=\(Thread.isMainThread ? "main" : "bg")")
        if scopesSnapshot.isEmpty {
            log("RunnerStore › ⚠️ fetch — activeScopes snapshot is EMPTY — buildGroupState will produce no actions")
        }
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else {
                log("RunnerStore › fetch background — self is nil, aborting")
                return
            }
            ghIsRateLimited = false
            let enrichedRunners = self.fetchAndEnrichRunners()
            let jobResult = self.buildJobState(snapPrev: snapPrev, snapCache: snapCache)
            let groupResult = self.buildGroupState(
                snapPrevGroups: snapPrevGroups,
                snapGroupCache: snapGroupCache,
                jobCache: jobResult.newCache
            )
            DispatchQueue.main.async {
                self.applyFetchResult(
                    enrichedRunners: enrichedRunners,
                    jobResult: jobResult,
                    groupResult: groupResult
                )
            }
        }
    }

    /// Applies a completed fetch result on the main thread.
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
        // Pass the freshly-fetched live groups so scheduleTimer evaluates
        // hasActive against real GitHub state, not the display cache which
        // may still contain frozen/completed groups.
        scheduleTimer(liveActions: groupResult.newPrevLiveGroups.map { $0.value })
    }

    func fetchAndEnrichRunners() -> [Runner] {
        log("RunnerStore › fetchAndEnrichRunners ENTER")
        var allRunners: [Runner] = []
        // Phase 4 (#503): activeScopes only.
        let scopes = ScopeStore.shared.activeScopes
        log("RunnerStore › fetchAndEnrichRunners — activeScopes=\(scopes)")
        for scope in scopes {
            let fetched = fetchRunners(for: scope)
            log("RunnerStore › fetchAndEnrichRunners — scope=\(scope) returned \(fetched.count) runner(s)")
            allRunners.append(contentsOf: fetched)
        }

        // Build a name→installPath lookup from LocalRunnerStore so metrics are matched
        // by installPath rather than slot index. The Runner API type has no installPath,
        // but the runner name matches the directory name used by the local install.
        // Accessing LocalRunnerStore.shared.runners must be done on the main thread;
        // we snapshot it here while still on the background queue via a sync hop.
        var installPathByName: [String: String] = [:]
        DispatchQueue.main.sync {
            for localRunner in LocalRunnerStore.shared.runners {
                if let path = localRunner.installPath {
                    installPathByName[localRunner.runnerName] = path
                }
            }
        }
        log("RunnerStore › fetchAndEnrichRunners — installPathByName keys=\(installPathByName.keys.sorted())")

        // Assign metrics per-runner by installPath. Only busy runners have an active
        // Worker/Listener process, so idle runners always receive nil.
        var result = allRunners
        for idx in result.indices {
            guard result[idx].busy else {
                result[idx].metrics = nil
                log("RunnerStore › fetchAndEnrichRunners — \(result[idx].name) is idle, metrics=nil")
                continue
            }
            guard let installPath = installPathByName[result[idx].name] else {
                log("RunnerStore › fetchAndEnrichRunners — \(result[idx].name) is busy but no local installPath found, metrics=nil")
                result[idx].metrics = nil
                continue
            }
            result[idx].metrics = metricsForRunner(installPath: installPath)
            log("RunnerStore › fetchAndEnrichRunners — \(result[idx].name) metrics=\(String(describing: result[idx].metrics))")
        }

        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
