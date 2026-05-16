import AppKit
import Combine
import Foundation

// MARK: - AggregateStatus

/// Represents the combined online/offline status across all registered runners.
enum AggregateStatus {
    /// All registered runners are online.
    case allOnline
    /// At least one runner is online and at least one is offline.
    case someOffline
    /// All registered runners are offline, or no runners are registered.
    case allOffline
    /// Emoji dot representation used in log output.
    var dot: String {
        switch self {
        case .allOnline: return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }
    /// SF Symbol name for SwiftUI `Image(systemName:)` calls.
    var symbolName: String {
        switch self {
        case .allOnline: return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
        }
    }
}

// MARK: - RunnerStore

/// Singleton polling store. Coordinates GitHub runner + job fetching on an adaptive interval.
///
/// Idle interval is read from `SettingsStore.shared.pollingInterval` and reacts to live changes
/// via a Combine subscription (no restart required when the user changes the stepper).
/// Active-job interval remains fixed at 10 s for responsiveness.
/// Call `start()` once at launch to begin polling.
/// Subscribe to `onChange` to be notified after each poll completes.
final class RunnerStore {
    /// Shared singleton — single source of truth for runner and job state.
    static let shared = RunnerStore()

    /// Currently known self-hosted runners. Main-thread only.
    private(set) var runners: [Runner] = []
    /// Jobs to display: live + recently completed (dimmed). Capped at 3. Main-thread only.
    private(set) var jobs: [ActiveJob] = []
    /// Action groups to display: live + recently completed (dimmed). Capped at 5. Main-thread only.
    private(set) var actions: [ActionGroup] = []

    // ⚠️ REGRESSION GUARD — completed job persistence (ref issue #54)
    // prevLiveJobs: full snapshot of LIVE jobs from the previous poll.
    // completedCache: ONLY reliable source of done jobs. NEVER clear between polls.
    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]

    // Action group persistence (mirrors completedCache pattern).
    // Key is head_sha — stable across polls even as run IDs change.
    private var prevLiveGroups: [String: ActionGroup] = [:]
    private var actionGroupCache: [String: ActionGroup] = [:]

    /// True when the most recent poll detected a GitHub rate-limit response.
    private(set) var isRateLimited = false

    /// One-shot adaptive poll timer. Rescheduled by `scheduleTimer()` after each fetch.
    private var timer: Timer?

    /// Combine cancellable — reacts to user changes to SettingsStore.pollingInterval.
    private var intervalCancellable: AnyCancellable?

    /// Called on the main thread after each poll completes.
    var onChange: (() -> Void)?

    /// Derives the aggregate runner status from the current `runners` array.
    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == "online" }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

    private init() {
        // dropFirst(1) skips the initial emission — start() handles the first schedule.
        intervalCancellable = SettingsStore.shared.$pollingInterval
            .dropFirst(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleTimer()
            }
    }

    /// Starts (or restarts) the polling timer and fires an immediate fetch.
    ///
    /// ⚠️ scheduleTimer() is called immediately (before the first fetch completes)
    /// so the run loop always has a live Timer from the moment start() returns.
    /// Without this, the app is a UIElement with no windows and no timers — macOS
    /// TAL kills it within ~2 seconds of applicationDidFinishLaunching returning.
    /// ❌ NEVER remove the scheduleTimer() call from this method.
    func start() {
        log("RunnerStore › start")
        timer?.invalidate()
        scheduleTimer()  // keep run loop alive immediately — before fetch() returns
        fetch()
    }

    /// Schedules the next one-shot poll timer using an adaptive interval.
    /// Idle base interval comes from `SettingsStore.shared.pollingInterval`.
    private func scheduleTimer() {
        timer?.invalidate()
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions = actions.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let baseIdle = max(10, SettingsStore.shared.pollingInterval)
        let interval: TimeInterval = (isRateLimited || !hasActive) ? TimeInterval(baseIdle) : 10
        log("RunnerStore › next poll in \(Int(interval))s (active=\(hasActive) rateLimited=\(isRateLimited))")
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            self?.fetch()
        }
    }

    /// Fetches runners, jobs, and action groups for all scopes on a background thread.
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

    // MARK: - Runner enrichment

    /// Fetches all runners across all scopes and assigns ps-based CPU/MEM metrics by slot index.
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
