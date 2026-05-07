import Foundation
import AppKit

// MARK: - AggregateStatus

/// Drives the status bar icon colour so the user can see runner health at a glance.
enum AggregateStatus {
    /// All registered runners are online.
    case allOnline
    /// At least one runner is online and at least one is offline.
    case someOffline
    /// All registered runners are offline, or no runners are registered.
    case allOffline

    /// SF Symbol name for use in SwiftUI `Image(systemName:)` calls.
    var symbolName: String {
        switch self {
        case .allOnline:   return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline:  return "circle"
        }
    }
}

// MARK: - Store

/// Singleton polling store that coordinates GitHub runner + job fetching every 10 seconds.
final class RunnerStore {
    /// Shared singleton — the single source of truth for runner and job state.
    static let shared = RunnerStore()

    /// All registered runners across all scopes.
    /// Updated on every poll. Must only be read and written on the main thread.
    private(set) var runners: [Runner] = []

    /// Jobs to display: live (in_progress/queued) + recently completed (dimmed).
    /// Capped at 3 entries. Updated on every poll. Main-thread only.
    private(set) var jobs: [ActiveJob] = []

    /// Action groups to display: live + recently completed (dimmed).
    /// Capped at 5 entries (matches ci-dash.py MAX_GROUPS). Main-thread only.
    private(set) var actions: [ActionGroup] = []

    /// `true` if the last API call returned a 403 or 429.
    private(set) var isRateLimited = false

    /// Subscribe to this closure to be notified whenever a poll completes.
    /// Use this to trigger a UI refresh (e.g. reload the observable or update the icon).
    var onChange: (() -> Void)?

    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]
    private var prevLiveGroups: [String: ActionGroup] = [:]
    private var actionGroupCache: [String: ActionGroup] = [:]

    private var timer: Timer?

    private init() {}

    /// Aggregate status for all runners.
    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let online = runners.filter { $0.status == "online" }.count
        if online == runners.count { return .allOnline }
        if online > 0 { return .someOffline }
        return .allOffline
    }

    /// Starts the auto-polling loop.
    func start() {
        log("RunnerStore › start")
        fetch()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let hasActive = !jobs.isEmpty || !actions.isEmpty
        let interval: TimeInterval = isRateLimited ? 60 : (hasActive ? 10 : 30)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        let snapPrev       = prevLiveJobs
        let snapCache      = completedCache
        let snapPrevGroups = prevLiveGroups
        let snapGroupCache = actionGroupCache

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            ghIsRateLimited = false

            let enrichedRunners = self.fetchEnrichedRunners()
            let allFetched = self.fetchAllJobs()

            let liveJobs  = allFetched.filter { $0.conclusion == nil && $0.status != "completed" }
            let freshDone = allFetched.filter { $0.conclusion != nil || $0.status == "completed" }
            let liveIDs   = Set(liveJobs.map { $0.id })

            var newCache = self.updateCompletedCache(
                snapCache: snapCache, snapPrev: snapPrev,
                liveIDs: liveIDs, freshDone: freshDone
            )
            newCache = self.backfillSteps(newCache: newCache)

            let display = self.prepareDisplayJobs(liveJobs: liveJobs, newCache: newCache)
            let newPrevLive = Dictionary(uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })

            let allFetchedGroups = self.fetchAllGroups()
            let (mergedDisplayGroups, mergedGroupCache, newPrevLiveGroups) = self.processGroups(
                allFetchedGroups: allFetchedGroups,
                snapGroupCache: snapGroupCache,
                snapPrevGroups: snapPrevGroups,
                newCache: newCache
            )

            DispatchQueue.main.async {
                self.runners          = enrichedRunners
                self.jobs             = display
                self.completedCache   = newCache
                self.prevLiveJobs     = newPrevLive
                self.actions          = mergedDisplayGroups
                self.actionGroupCache = mergedGroupCache
                self.prevLiveGroups   = newPrevLiveGroups
                self.isRateLimited    = ghIsRateLimited
                self.onChange?()
                self.scheduleTimer()
            }
        }
    }

    private func fetchEnrichedRunners() -> [Runner] {
        var allRunners: [Runner] = []
        for scope in ScopeStore.shared.scopes {
            allRunners.append(contentsOf: fetchRunners(for: scope))
        }
        let metrics = allWorkerMetrics()
        var busy = allRunners.filter { $0.busy }
        var idle = allRunners.filter { !$0.busy }
        for idx in busy.indices { busy[idx].metrics = idx < metrics.count ? metrics[idx] : nil }
        for idx in idle.indices {
            let metricsIdx = busy.count + idx
            idle[idx].metrics = metricsIdx < metrics.count ? metrics[metricsIdx] : nil
        }
        return busy + idle
    }

    private func fetchAllJobs() -> [ActiveJob] {
        var allFetched: [ActiveJob] = []
        for scope in ScopeStore.shared.scopes {
            allFetched.append(contentsOf: fetchActiveJobs(for: scope))
        }
        return allFetched
    }

    private func updateCompletedCache(
        snapCache: [Int: ActiveJob],
        snapPrev: [Int: ActiveJob],
        liveIDs: Set<Int>,
        freshDone: [ActiveJob]
    ) -> [Int: ActiveJob] {
        var newCache = snapCache
        let now = Date()
        for (id, job) in snapPrev where !liveIDs.contains(id) {
            guard newCache[id] == nil else { continue }
            newCache[id] = ActiveJob(
                id: job.id, name: job.name, status: "completed",
                conclusion: job.conclusion ?? "success", startedAt: job.startedAt,
                createdAt: job.createdAt, completedAt: job.completedAt ?? now,
                htmlUrl: job.htmlUrl, isDimmed: true, steps: job.steps
            )
        }
        for job in freshDone {
            newCache[job.id] = ActiveJob(
                id: job.id, name: job.name, status: "completed",
                conclusion: job.conclusion ?? "success", startedAt: job.startedAt,
                createdAt: job.createdAt, completedAt: job.completedAt ?? Date(),
                htmlUrl: job.htmlUrl, isDimmed: true, steps: job.steps
            )
        }
        if newCache.count > 3 {
            let sorted = newCache.values.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            newCache = Dictionary(uniqueKeysWithValues: sorted.prefix(3).map { ($0.id, $0) })
        }
        return newCache
    }

    private func backfillSteps(newCache: [Int: ActiveJob]) -> [Int: ActiveJob] {
        var result = newCache
        let iso = ISO8601DateFormatter()
        for id in Array(result.keys) {
            let cached = result[id]!
            let needsBackfill = cached.conclusion != nil &&
                (cached.steps.isEmpty || cached.steps.contains { $0.status == "in_progress" })
            guard needsBackfill else { continue }
            guard let scope = scopeFromHtmlUrl(cached.htmlUrl),
                  let data = ghAPI("repos/\(scope)/actions/jobs/\(id)"),
                  let fresh = try? JSONDecoder().decode(JobPayload.self, from: data) else { continue }
            result[id] = makeActiveJob(from: fresh, iso: iso, isDimmed: true)
        }
        return result
    }

    private func prepareDisplayJobs(liveJobs: [ActiveJob], newCache: [Int: ActiveJob]) -> [ActiveJob] {
        let inProgress = liveJobs.filter { $0.status == "in_progress" }
        let queued     = liveJobs.filter { $0.status == "queued" }
        let cached     = newCache.values.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        var display: [ActiveJob] = []
        for job in inProgress where display.count < 3 { display.append(job) }
        for job in queued     where display.count < 3 { display.append(job) }
        for job in cached     where display.count < 3 { display.append(job) }
        return display
    }

    private func fetchAllGroups() -> [ActionGroup] {
        var allFetchedGroups: [ActionGroup] = []
        let shaKeyedGroupCache = Dictionary(uniqueKeysWithValues: actionGroupCache.values.map { ($0.headSha, $0) })
        for scope in ScopeStore.shared.scopes {
            allFetchedGroups.append(contentsOf: fetchActionGroups(for: scope, cache: shaKeyedGroupCache))
        }
        return allFetchedGroups
    }

    private func processGroups(
        allFetchedGroups: [ActionGroup],
        snapGroupCache: [String: ActionGroup],
        snapPrevGroups: [String: ActionGroup],
        newCache: [Int: ActiveJob]
    ) -> ([ActionGroup], [String: ActionGroup], [String: ActionGroup]) {
        let liveGroups = allFetchedGroups.filter { $0.groupStatus != .completed }
        let doneGroups = allFetchedGroups.filter { $0.groupStatus == .completed }
        let liveGroupIDs = Set(liveGroups.map { $0.id })
        var newGroupCache = snapGroupCache

        let freshHeadShas = Set(allFetchedGroups.map { $0.headSha })
        newGroupCache = newGroupCache.filter { !freshHeadShas.contains($1.headSha) }

        for (sha, group) in snapPrevGroups where !liveGroupIDs.contains(sha) {
            if let existing = newGroupCache[sha],
               existing.isDimmed,
               existing.jobs.count >= group.jobs.count { continue }
            var frozen = group
            frozen.isDimmed = true
            if frozen.lastJobCompletedAt == nil {
                frozen = ActionGroup(
                    headSha: frozen.headSha, label: frozen.label, title: frozen.title,
                    headBranch: frozen.headBranch, repo: frozen.repo, runs: frozen.runs,
                    jobs: frozen.jobs, firstJobStartedAt: frozen.firstJobStartedAt,
                    lastJobCompletedAt: Date(), createdAt: frozen.createdAt, isDimmed: true
                )
            }
            newGroupCache[sha] = frozen
        }

        for group in doneGroups {
            var dimmed = group
            dimmed.isDimmed = true
            newGroupCache[group.id] = dimmed
        }

        if newGroupCache.count > 5 {
            let sorted = newGroupCache.values.sorted {
                ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast) >
                ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
            }
            newGroupCache = Dictionary(uniqueKeysWithValues: sorted.prefix(5).map { ($0.id, $0) })
        }

        let newPrevLiveGroups = Dictionary(uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
        let inProgressGroups = liveGroups.filter { $0.groupStatus == .inProgress }
        let queuedGroups     = liveGroups.filter { $0.groupStatus == .queued }
        let cachedGroups     = newGroupCache.values.sorted {
            ($0.lastJobCompletedAt ?? $0.createdAt ?? .distantPast) >
            ($1.lastJobCompletedAt ?? $1.createdAt ?? .distantPast)
        }
        let liveGroupIDsInDisplay = Set((inProgressGroups + queuedGroups).map { $0.id })

        var displayGroups: [ActionGroup] = []
        for group in inProgressGroups where displayGroups.count < 5 { displayGroups.append(group) }
        for group in queuedGroups     where displayGroups.count < 5 { displayGroups.append(group) }
        for group in cachedGroups     where displayGroups.count < 5 && !liveGroupIDsInDisplay.contains(group.id) {
            displayGroups.append(group)
        }

        let enricher = { (jobs: [ActiveJob]) -> [ActiveJob] in
            jobs.map { job in
                if job.conclusion == nil, let hit = newCache[job.id], hit.conclusion != nil {
                    return ActiveJob(id: job.id, name: job.name, status: hit.status, conclusion: hit.conclusion,
                                     steps: job.steps.isEmpty ? hit.steps : job.steps,
                                     startedAt: job.startedAt ?? hit.startedAt,
                                     createdAt: job.createdAt ?? hit.createdAt,
                                     completedAt: hit.completedAt ?? job.completedAt,
                                     htmlUrl: job.htmlUrl ?? hit.htmlUrl, isDimmed: false)
                }
                if job.conclusion == nil, job.completedAt != nil {
                    return ActiveJob(id: job.id, name: job.name, status: "completed", conclusion: "success",
                                     steps: job.steps, startedAt: job.startedAt, createdAt: job.createdAt,
                                     completedAt: job.completedAt, htmlUrl: job.htmlUrl, isDimmed: false)
                }
                if job.conclusion == nil, job.status == "completed" {
                    return ActiveJob(id: job.id, name: job.name, status: "completed", conclusion: "success",
                                     steps: job.steps, startedAt: job.startedAt, createdAt: job.createdAt,
                                     completedAt: job.completedAt, htmlUrl: job.htmlUrl, isDimmed: false)
                }
                if job.conclusion == nil, job.status == "in_progress", let started = job.startedAt,
                   Date().timeIntervalSince(started) > 600 {
                    return ActiveJob(id: job.id, name: job.name, status: "completed", conclusion: "success",
                                     steps: job.steps, startedAt: job.startedAt, createdAt: job.createdAt,
                                     completedAt: job.completedAt ?? started.addingTimeInterval(600),
                                     htmlUrl: job.htmlUrl, isDimmed: false)
                }
                return job
            }
        }

        let mergedDisplay = displayGroups.map { $0.withJobs(enricher($0.jobs)) }
        let mergedCache   = newGroupCache.mapValues { $0.withJobs(enricher($0.jobs)) }
        return (mergedDisplay, mergedCache, newPrevLiveGroups)
    }
}
