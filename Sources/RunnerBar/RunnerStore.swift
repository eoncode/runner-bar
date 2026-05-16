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
    private var cancellables = Set<AnyCancellable>()
    var onChange: (() -> Void)?

    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == "online" }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

    private init() {
        SettingsStore.shared.$pollingInterval
            .dropFirst(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)

        // Re-fetch immediately when scopes are added or removed so the
        // popover reflects the new scope without requiring an app restart.
        ScopeStore.shared.$scopes
            .dropFirst(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.timer?.invalidate()
                self?.fetch()
            }
            .store(in: &cancellables)
    }

    func start() {
        log("RunnerStore › start")
        // Seed ScopeStore from SettingsStore.githubOrg if scopes are empty.
        // Covers existing installs that saved credentials before ScopeStore
        // was introduced, and fresh installs before the user visits Settings.
        // ❌ NEVER remove — without this, polling returns empty on every launch
        // for users who have a githubOrg saved but no explicit scopes.
        if ScopeStore.shared.scopes.isEmpty {
            let org = SettingsStore.shared.githubOrg.trimmingCharacters(in: .whitespaces)
            if !org.isEmpty {
                ScopeStore.shared.add(org)
                log("RunnerStore › seeded ScopeStore with org: \(org)")
            }
        }
        timer?.invalidate()
        fetch()
    }

    private func hasAnyActiveAction() -> Bool {
        for action in actions {
            let s = action.groupStatus
            if s == "in_progress" { return true }
            if s == "queued" { return true }
        }
        return false
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let hasActiveJobs: Bool = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions: Bool = hasAnyActiveAction()
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, SettingsStore.shared.pollingInterval)
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › next poll in \(Int(interval))s (active=\(hasActive) rateLimited=\(isRateLimited))")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            ghIsRateLimited = false
            let enrichedRunners = self.fetchAndEnrichRunners()
            let jobResult = self.buildJobState(snapPrev: snapPrev, snapCache: snapCache)
            let groupResult = self.buildGroupState(
                snapPrevGroups: snapPrevGroups,
                snapGroupCache: snapGroupCache,
                jobCache: jobResult.newCache
            )
            DispatchQueue.main.async {
                self.runners = enrichedRunners
                self.jobs = jobResult.display
                self.completedCache = jobResult.newCache
                self.prevLiveJobs = jobResult.newPrevLive
                self.actions = groupResult.display
                self.actionGroupCache = groupResult.newGroupCache
                self.prevLiveGroups = groupResult.newPrevLiveGroups
                self.isRateLimited = ghIsRateLimited
                self.onChange?()
                self.scheduleTimer()
            }
        }
    }

    func fetchAndEnrichRunners() -> [Runner] {
        var allRunners: [Runner] = []
        for scope in ScopeStore.shared.scopes {
            allRunners.append(contentsOf: fetchRunners(for: scope))
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
        return busyRunners + idleRunners
    }
}
