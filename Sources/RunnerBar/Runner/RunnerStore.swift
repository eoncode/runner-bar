import AppKit
import Combine
import Foundation

// MARK: - AggregateStatus

enum AggregateStatus {
    case allOnline
    case someOffline
    case allOffline
    var dot: String {
        switch self {
        case .allOnline: return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }
    var symbolName: String {
        switch self {
        case .allOnline: return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
        }
    }
}

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
    var onChange: (() -> Void)?

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
        onChange?()
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
        let metrics = allWorkerMetrics()
        var busyRunners = allRunners.filter { $0.busy }
        var idleRunners = allRunners.filter { !$0.busy }
        for idx in busyRunners.indices {
            busyRunners[idx].metrics = idx < metrics.count ? metrics[idx] : nil
        }
        for idx in idleRunners.indices {
            let slotIdx = busyRunners.count + idx
            idleRunners[idx].metrics = slotIdx < metrics.count ? metrics[slotIdx] : nil
        }
        let result = busyRunners + idleRunners
        log("RunnerStore › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)")
        return result
    }
}
