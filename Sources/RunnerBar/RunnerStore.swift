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
        case .allOnline:  return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }

    /// SF Symbol name for use in SwiftUI `Image(systemName:)` calls.
    var symbolName: String {
        switch self {
        case .allOnline:  return "circle.fill"
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

    // —— Action group persistence (mirrors completedCache pattern)
    // prevLiveGroups: live ActionGroup snapshot from the previous poll.
    // actionGroupCache: persists completed groups keyed by head_sha (String).
    // - NEVER clear between polls.
    // - Key is head_sha — stable across polls even as run IDs change.
    // - Trimmed to newest 5 entries (ci-dash.py MAX_GROUPS = 5).
    // ⚠️ Snapshots MUST be taken on the main thread before the background block.
    private var prevLiveGroups: [String: ActionGroup] = [:]
    private var actionGroupCache: [String: ActionGroup] = [:]

    /// True when the most recent poll cycle detected a GitHub rate-limit response.
    /// Drives the 60s backoff interval and the UI warning row.
    private(set) var isRateLimited = false

    /// One-shot adaptive poll timer. Rescheduled by `scheduleTimer()` after each fetch.
    /// Held strongly so it is not deallocated between polls.
    private var timer: Timer?

    /// Called on the main thread after each poll completes.
    /// Use this to trigger a UI refresh (e.g. reload the observable or update the icon).
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
    /// Invalidates any existing timer first. The next timer is scheduled adaptively
    /// inside `fetch()`'s main.async block once results are available.
    func start() {
        log("RunnerStore › start")
        timer?.invalidate()
        fetch()
    }

    /// Schedules the next one-shot poll timer using an adaptive interval:
    /// - 10 s when any job or group is actively running (in_progress / queued)
    /// - 60 s when idle or rate-limited
    ///
    /// Always invalidates the previous timer first so calling this more than once
    /// cannot accumulate stacked timers.
    /// Must be called on the main thread (reads main-thread-owned state).
    private func scheduleTimer() {
        timer?.invalidate()
        let hasActive = jobs.contains { $0.status == "in_progress" || $0.status == "queued" }
            || actions.contains { $0.groupStatus == .inProgress || $0.groupStatus == .queued }
        let interval: TimeInterval = (isRateLimited || !hasActive) ? 60 : 10
        log("RunnerStore › next poll in \(Int(interval))s (active=\(hasActive) rateLimited=\(isRateLimited))")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetch()
        }
    }

    /// Fetches runners, active jobs, and action groups for all scopes on a background thread.
    ///
    /// Algorithm (jobs):
    /// 1. Fetch runners via `fetchRunners(for:)` and enrich with local `ps aux` metrics.
    /// 2. Fetch active jobs via `fetchActiveJobs(for:)` for every scope.
    /// 3. Diff live jobs against `prevLiveJobs` to detect vanished jobs and freeze them
    ///    into `completedCache`.
    /// 4. Add freshly-concluded jobs (conclusion != nil in still-active runs) to cache.
    /// 5. Trim cache to the 3 most-recently-completed jobs.
    /// 6. Build the display list: in_progress → queued → cached done (newest first), capped at 3.
    func fetch() {
        // ⚠️ Snapshot mutable state on the main thread BEFORE the background block.
        let snapPrev = prevLiveJobs
        let snapCache = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }

            // Reset rate-limit flag for this poll cycle.
            ghIsRateLimited = false

            let enrichedRunners = self.fetchAndEnrichRunners()
            let (display, newCache, newPrevLive) = self.buildJobState(
                snapPrev: snapPrev, snapCache: snapCache
            )
            let (displayGroups, newGroupCache, newPrevLiveGroups) = self.buildGroupState(
                snapPrevGroups: snapPrevGroups,
                snapGroupCache: snapGroupCache,
                jobCache: newCache
            )

            // All property writes must happen on the main thread.
            DispatchQueue.main.async {
                self.runners          = enrichedRunners
                self.jobs             = display
                self.completedCache   = newCache
                self.prevLiveJobs     = newPrevLive
                self.actions          = displayGroups
                self.actionGroupCache = newGroupCache
                self.prevLiveGroups   = newPrevLiveGroups
                self.isRateLimited    = ghIsRateLimited
                self.onChange?()
                self.scheduleTimer()
            }
        }
    }

    // MARK: - Private fetch helpers

    /// Fetches all runners across all scopes and assigns ps-based CPU/MEM metrics by slot index.
    private func fetchAndEnrichRunners() -> [Runner] {
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

    /// Builds the job display list and updated caches from a background poll.
    /// Returns (displayJobs, newCompletedCache, newPrevLiveJobs).
    private func buildJobState(
        snapPrev: [Int: ActiveJob],
        snapCache: [Int: ActiveJob]
    ) -> ([ActiveJob], [Int: ActiveJob], [Int: ActiveJob]) {
        var allFetched: [ActiveJob] = []
        for scope in ScopeStore.shared.scopes {
            allFetched.append(contentsOf: fetchActiveJobs(for: scope))
        }
        let liveJobs  = allFetched.filter { $0.conclusion == nil && $0.status != "completed" }
        let freshDone = allFetched.filter { $0.conclusion != nil || $0.status == "completed" }
        let liveIDs   = Set(liveJobs.map { $0.id })
        let now       = Date()
        var newCache  = snapCache

        // ⚠️ CALLSITE 2 of 3 — Vanished jobs: were live last poll, gone now.
        for (jobID, job) in snapPrev where !liveIDs.contains(jobID) {
            guard newCache[jobID] == nil else { continue }
            newCache[jobID] = ActiveJob(
                id: job.id, name: job.name, status: "completed",
                conclusion: job.conclusion ?? "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt ?? now,
                htmlUrl: job.htmlUrl, isDimmed: true, steps: job.steps
            )
        }

        // ⚠️ CALLSITE 3 of 3 — Fresh done: jobs with a conclusion inside active runs.
        for job in freshDone {
            newCache[job.id] = ActiveJob(
                id: job.id, name: job.name, status: "completed",
                conclusion: job.conclusion ?? "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt ?? Date(),
                htmlUrl: job.htmlUrl, isDimmed: true, steps: job.steps
            )
        }

        // Trim to newest 3 to cap memory usage.
        if newCache.count > 3 {
            let sortedCache = newCache.values
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            newCache = Dictionary(
                uniqueKeysWithValues: sortedCache.prefix(3).map { ($0.id, $0) }
            )
        }

        // Backfill steps for cached jobs that concluded with empty steps (#110/#111).
        let backfillIso = ISO8601DateFormatter()
        for cacheID in Array(newCache.keys) {
            let cached = newCache[cacheID]! // swiftlint:disable:this force_unwrapping
            guard cached.conclusion != nil,
                  (cached.steps.isEmpty || cached.steps.contains(where: { $0.status == "in_progress" })),
                  let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = ghAPI("repos/\(scope)/actions/jobs/\(cacheID)"),
                  let fresh = try? JSONDecoder().decode(JobPayload.self, from: data),
                  let rawSteps = fresh.steps,
                  !rawSteps.isEmpty
            else { continue }
            newCache[cacheID] = makeActiveJob(from: fresh, iso: backfillIso, isDimmed: true)
        }

        let newPrevLive = Dictionary(uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })

        // Display order: in_progress → queued → done (newest first), max 3 total.
        let inProgress = liveJobs.filter { $0.status == "in_progress" }
        let queued     = liveJobs.filter { $0.status == "queued" }
        let cached     = newCache.values
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        var display: [ActiveJob] = []
        for job in inProgress where display.count < 3 { display.append(job) }
        for job in queued     where display.count < 3 { display.append(job) }
        for job in cached     where display.count < 3 { display.append(job) }
        log(
            "RunnerStore › \(inProgress.count) in_progress \(queued.count) queued | "
            + "cache: \(newCache.count) | display: \(display.count)"
        )
        return (display, newCache, newPrevLive)
    }

    /// Builds the action-group display list and updated caches from a background poll.
    /// Returns (displayGroups, newGroupCache, newPrevLiveGroups).
    private func buildGroupState(
        snapPrevGroups: [String: ActionGroup],
        snapGroupCache: [String: ActionGroup],
        jobCache: [Int: ActiveJob]
    ) -> ([ActionGroup], [String: ActionGroup], [String: ActionGroup]) {
        let shaKeyedGroupCache: [String: ActionGroup] = Dictionary(
            snapGroupCache.values.map { ($0.headSha, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
        )
        var allFetchedGroups: [ActionGroup] = []
        for scope in ScopeStore.shared.scopes {
            allFetchedGroups.append(
                contentsOf: fetchActionGroups(for: scope, cache: shaKeyedGroupCache)
            )
        }
        let liveGroups     = allFetchedGroups.filter { $0.groupStatus != .completed }
        let doneGroups     = allFetchedGroups.filter { $0.groupStatus == .completed }
        let liveGroupIDs   = Set(liveGroups.map { $0.id })
        let nowGroups      = Date()
        var newGroupCache  = snapGroupCache

        // Evict any cached entry whose head_sha matches a freshly-fetched group.
        let freshHeadShas = Set(allFetchedGroups.map { $0.headSha })
        newGroupCache = newGroupCache.filter { _, cachedGroup in
            !freshHeadShas.contains(cachedGroup.headSha)
        }

        // Vanished groups: were live last poll, absent now — freeze.
        for (sha, group) in snapPrevGroups where !liveGroupIDs.contains(sha) {
            if let existing = newGroupCache[sha],
               existing.isDimmed,
               existing.jobs.count >= group.jobs.count { continue }
            var frozen = group
            frozen.isDimmed = true
            if frozen.lastJobCompletedAt == nil {
                frozen = ActionGroup(
                    headSha: frozen.headSha, label: frozen.label,
                    title: frozen.title, headBranch: frozen.headBranch,
                    repo: frozen.repo, runs: frozen.runs, jobs: frozen.jobs,
                    firstJobStartedAt: frozen.firstJobStartedAt,
                    lastJobCompletedAt: nowGroups, createdAt: frozen.createdAt,
                    isDimmed: true
                )
            }
            newGroupCache[sha] = frozen
        }

        // Fresh-done groups: concluded in this poll.
        for group in doneGroups {
            var dimmed = group
            dimmed.isDimmed = true
            newGroupCache[group.id] = dimmed
        }

        // Trim to newest 5 (ci-dash.py MAX_GROUPS = 5).
        if newGroupCache.count > 5 {
            let sortedGroups = newGroupCache.values.sorted {
                ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
                > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
            }
            newGroupCache = Dictionary(
                uniqueKeysWithValues: sortedGroups.prefix(5).map { ($0.id, $0) }
            )
        }

        let newPrevLiveGroups = Dictionary(uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })

        // Display: in_progress → queued → cached done (newest first), max 5.
        let inProgressGroups = liveGroups.filter { $0.groupStatus == .inProgress }
        let queuedGroups     = liveGroups.filter { $0.groupStatus == .queued }
        let cachedGroups     = newGroupCache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast)
            > ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        let liveGroupIDsInDisplay = Set((inProgressGroups + queuedGroups).map { $0.id })
        var displayGroups: [ActionGroup] = []
        for grp in inProgressGroups where displayGroups.count < 5 { displayGroups.append(grp) }
        for grp in queuedGroups     where displayGroups.count < 5 { displayGroups.append(grp) }
        for grp in cachedGroups where displayGroups.count < 5 && !liveGroupIDsInDisplay.contains(grp.id) {
            displayGroups.append(grp)
        }
        log(
            "RunnerStore › groups: \(inProgressGroups.count) in_progress "
            + "\(queuedGroups.count) queued | cache: \(newGroupCache.count) | display: \(displayGroups.count)"
        )

        let mergedDisplayGroups = displayGroups.map { $0.withJobs(enrichGroupJobs($0.jobs, jobCache: jobCache)) }
        let mergedGroupCache    = newGroupCache.mapValues { $0.withJobs(enrichGroupJobs($0.jobs, jobCache: jobCache)) }

        return (mergedDisplayGroups, mergedGroupCache, newPrevLiveGroups)
    }
}

// MARK: - Group job enrichment

/// Cross-references group jobs with the completed-job cache to fill in
/// conclusion/timestamps that the batch API may not yet have propagated.
/// Extracted from `buildGroupState` to reduce cyclomatic complexity (issue #96).
private func enrichGroupJobs(_ groupJobs: [ActiveJob], jobCache: [Int: ActiveJob]) -> [ActiveJob] {
    groupJobs.map { job in
        // Primary: substitute from completedCache when available.
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
        // Secondary: completedAt is set but conclusion not yet propagated (#103).
        if job.conclusion == nil, job.completedAt != nil {
            return ActiveJob(
                id: job.id, name: job.name, status: "completed", conclusion: "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt, htmlUrl: job.htmlUrl,
                isDimmed: false, steps: job.steps
            )
        }
        // Tertiary: status already "completed" but conclusion/completedAt still nil.
        if job.conclusion == nil, job.status == "completed" {
            return ActiveJob(
                id: job.id, name: job.name, status: "completed", conclusion: "success",
                startedAt: job.startedAt, createdAt: job.createdAt,
                completedAt: job.completedAt, htmlUrl: job.htmlUrl,
                isDimmed: false, steps: job.steps
            )
        }
        // Quinary: job has been in_progress for >10 min with no conclusion.
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
