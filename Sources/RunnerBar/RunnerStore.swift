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

/// Singleton polling store. Coordinates GitHub runner + job fetching on a configurable interval.
///
/// Owns the canonical `runners` and `jobs` arrays consumed by the UI layer.
/// Call `start()` once at launch to begin polling.
/// Subscribe to `onChange` to be notified after each poll completes.
///
/// Polling interval is read from `SettingsStore.shared.pollingInterval` at each reschedule.
/// Changing the stepper in Settings takes effect at the next reschedule (within one poll cycle)
/// via the Combine subscription on `$pollingInterval` which calls `start()` immediately.
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

    /// Cancellable for the SettingsStore.pollingInterval subscription.
    /// Cancels automatically when RunnerStore is deallocated (never in practice — it's a singleton).
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
        // Subscribe to pollingInterval changes. When the user adjusts the stepper in Settings,
        // restart the timer immediately so the new interval takes effect without waiting for
        // the current in-flight countdown to expire (ref #221 self-review).
        // dropFirst(1): skip the initial value emitted on subscription — start() handles that.
        intervalCancellable = SettingsStore.shared.$pollingInterval
            .dropFirst(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.start()
            }
    }

    /// Starts (or restarts) the polling timer and fires an immediate fetch.
    func start() {
        log("RunnerStore › start")
        timer?.invalidate()
        fetch()
    }

    /// Schedules the next one-shot poll timer.
    ///
    /// Interval logic:
    /// - Rate-limited: always 60 s (GitHub asks for back-off).
    /// - Active jobs/actions: half the user-configured interval, floored at 10 s
    ///   (keeps live views responsive without hammering the API).
    /// - Idle: full user-configured interval from SettingsStore.
    private func scheduleTimer() {
        timer?.invalidate()
        let configured = TimeInterval(SettingsStore.shared.pollingInterval)
        let hasActiveJobs = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
        let hasActiveActions = actions.contains {
            $0.groupStatus == .inProgress || $0.groupStatus == .queued
        }
        let hasActive = hasActiveJobs || hasActiveActions
        let interval: TimeInterval
        if isRateLimited {
            interval = 60
        } else if hasActive {
            interval = max(10, configured / 2)
        } else {
            interval = configured
        }
        log("RunnerStore › next poll in \(Int(interval))s (active=\(hasActive) rateLimited=\(isRateLimited) configured=\(Int(configured))s)")
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
