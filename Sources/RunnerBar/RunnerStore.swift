import AppKit
import Foundation

// MARK: - Aggregate status

/// Represents the combined online/offline status across all registered runners.
/// Drives the status bar icon colour so the user can see runner health at a glance.
enum AggregateStatus {
    /// All registered runners are online.
    case allOnline
    /// At least one runner is online and at least one is offline.
    case someOffline
    /// All registered runners are offline, or no runners are registered.
    case allOffline

    /// Emoji dot representation, used in log output for quick visual scanning.
    var dot: String {
        switch self {
        case .allOnline: return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }

    /// SF Symbol name for use in SwiftUI `Image(systemName:)` calls.
    var symbolName: String {
        switch self {
        case .allOnline: return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
        }
    }
}

// MARK: - Store

/// Singleton polling store that coordinates GitHub runner + job fetching every 10 seconds.
///
/// Owns the canonical `runners` and `jobs` arrays consumed by the UI layer.
/// Call `start()` once at launch (or whenever a new scope is added) to begin polling.
/// Subscribe to `onChange` to be notified after each poll completes.
final class RunnerStore {
    /// Shared singleton — the single source of truth for runner and job state.
    static let shared = RunnerStore()

    /// Currently known self-hosted runners, enriched with local process metrics.
    /// Updated on every poll. Must only be read and written on the main thread.
    private(set) var runners: [Runner] = []

    /// Jobs to display: live (in_progress/queued) + recently completed (dimmed).
    /// Capped at 3 entries. Updated on every poll. Main-thread only.
    private(set) var jobs: [ActiveJob] = []

    /// Action groups to display: live + recently completed (dimmed).
    /// Capped at 5 entries (matches ci-dash.py MAX_GROUPS). Main-thread only.
    private(set) var actions: [ActionGroup] = []

    // ⚠️ REGRESSION GUARD — completed job persistence (ref issue #54)
    // prevLiveJobs: full snapshot of the LIVE jobs from the previous poll.
    // completedCache: the ONLY reliable source of done jobs.
    // - NEVER clear this between polls.
    // - NEVER replace with fetchRecentCompletedJobs() alone.
    // - Jobs are frozen in from TWO sources every poll:
    //   a) jobs with conclusion != nil inside still-active runs (immediate)
    //   b) jobs that disappear from prevLiveJobs between polls (vanished)
    // - Trimmed to newest 3 entries to cap memory.
    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]

    // Action group persistence (mirrors completedCache pattern).
    // Key is head_sha — stable across polls even as run IDs change.
    // Trimmed to newest 5 entries (ci-dash.py MAX_GROUPS = 5).
    // ⚠️ Snapshots MUST be taken on the main thread before the background block.
    private var prevLiveGroups: [String: ActionGroup] = [:]
    private var actionGroupCache: [String: ActionGroup] = [:]

    /// True when the most recent poll cycle detected a GitHub rate-limit response.
    /// Drives the 60s backoff interval and the UI warning row.
    private(set) var isRateLimited = false

    /// One-shot adaptive poll timer. Rescheduled by `scheduleTimer()` after each fetch.
    private var timer: Timer?

    /// Called on the main thread after each poll completes.
    var onChange: (() -> Void)?

    /// Derives the aggregate runner status from the current `runners` array.
    /// Returns `.allOffline` when `runners` is empty (no scopes configured yet).
    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == "online" }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

    /// Starts (or restarts) the polling timer and fires an immediate fetch.
    func start() {
        log("RunnerStore › start")
        timer?.invalidate()
        fetch()
    }

    /// Schedules the next one-shot poll timer using an adaptive interval:
    /// 10 s when active, 60 s when idle or rate-limited.
    private func scheduleTimer() {
        timer?.invalidate()
        let hasActive = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
            || actions.contains { $0.groupStatus == .inProgress || $0.groupStatus == .queued }
        let interval: TimeInterval = (isRateLimited || !hasActive) ? 60 : 10
        log("RunnerStore › next poll in \(Int(interval))s (active=\(hasActive) rateLimited=\(isRateLimited))")
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false,
            block: { [weak self] _ in self?.fetch() }
        )
    }

    /// Fetches runners, jobs, and action groups for all scopes on a background thread.
    func fetch() {
        let snapPrev        = prevLiveJobs
        let snapCache       = completedCache
        let snapPrevGroups  = prevLiveGroups
        let snapGroupCache  = actionGroupCache

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
                self.runners          = enrichedRunners
                self.jobs             = jobResult.display
                self.completedCache   = jobResult.newCache
                self.prevLiveJobs     = jobResult.newPrevLive
                self.actions          = groupResult.display
                self.actionGroupCache = groupResult.newGroupCache
                self.prevLiveGroups   = groupResult.newPrevLiveGroups
                self.isRateLimited    = ghIsRateLimited
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
        for busyIdx in busyRunners.indices {
            busyRunners[busyIdx].metrics = busyIdx < metrics.count ? metrics[busyIdx] : nil
        }
        for idleIdx in idleRunners.indices {
            let slotIdx = busyRunners.count + idleIdx
            idleRunners[idleIdx].metrics = slotIdx < metrics.count ? metrics[slotIdx] : nil
        }
        return busyRunners + idleRunners
    }
}

// MARK: - Group job enrichment

/// Cross-references group jobs with the completed-job cache to fill in
/// conclusion/timestamps that the batch API may not yet have propagated.
private func enrichGroupJobs(_ groupJobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
    groupJobs.map { job in
        if job.conclusion == nil, let hit = jobCache[job.id], hit.conclusion != nil {
            return ActiveJob(
                id: job.id, name: job.name, status: hit.status,
                conclusion: hit.conclusion,
                startedAt: job.startedAt ?? hit.startedAt,
                createdAt: job.createdAt ?? hit.createdAt,
                completedAt: hit.completedAt ?? job.completedAt,
                htmlUrl: job.htmlUrl ?? hit.htmlUrl,
                isDimmed: false,
                steps: job.steps.isEmpty ? hit.steps : job.steps
            )
        }
        if job.conclusion == nil, job.completedAt != nil {
            return ActiveJob(
                id: job.id, name: job.name, status: "completed", conclusion: "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt, htmlUrl: job.htmlUrl,
                isDimmed: false, steps: job.steps
            )
        }
        if job.conclusion == nil, job.status == "completed" {
            return ActiveJob(
                id: job.id, name: job.name, status: "completed", conclusion: "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt, htmlUrl: job.htmlUrl,
                isDimmed: false, steps: job.steps
            )
        }
        if job.conclusion == nil, job.status == "in_progress",
           let started = job.startedAt, Date().timeIntervalSince(started) > 600 {
            return ActiveJob(
                id: job.id, name: job.name, status: "completed", conclusion: "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt ?? started.addingTimeInterval(600),
                htmlUrl: job.htmlUrl, isDimmed: false, steps: job.steps
            )
        }
        return job
    }
}
