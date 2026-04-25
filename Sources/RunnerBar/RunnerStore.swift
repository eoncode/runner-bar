import Foundation
import AppKit

// MARK: - Aggregate status

enum AggregateStatus {
    case allOnline, someOffline, allOffline
    var dot: String {
        switch self {
        case .allOnline:   return "🟢"
        case .someOffline: return "🟡"
        case .allOffline:  return "⚫"
        }
    }
    var symbolName: String {
        switch self {
        case .allOnline:   return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline:  return "circle"
        }
    }
}

// MARK: - Store

final class RunnerStore {
    static let shared = RunnerStore()

    private(set) var runners: [Runner] = []
    private(set) var jobs: [ActiveJob] = []

    // ⚠️ REGRESSION GUARD — completed job persistence (ref issue #54)
    // prevLiveJobs: full snapshot of the LIVE jobs from the previous poll.
    //   Used to detect vanished jobs (were live, now gone) and freeze them into cache.
    // completedCache: the ONLY reliable source of done jobs.
    //   - NEVER clear this between polls — persistence depends on it surviving.
    //   - NEVER replace with fetchRecentCompletedJobs() alone — GitHub API lags
    //     10-30 seconds before marking a run 'completed', causing done jobs to vanish.
    //   - Jobs are frozen in from TWO sources every poll:
    //       a) jobs with conclusion != nil inside still-active runs (immediate)
    //       b) jobs that disappear from prevLiveJobs between polls (vanished)
    //   - Trimmed to newest 3 entries to cap memory.
    private var prevLiveJobs: [Int: ActiveJob] = [:]
    private var completedCache: [Int: ActiveJob] = [:]

    private var timer: Timer?
    var onChange: (() -> Void)?

    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let online = runners.filter { $0.status == "online" }.count
        if online == runners.count { return .allOnline }
        if online == 0             { return .allOffline }
        return .someOffline
    }

    func start() {
        log("RunnerStore › start")
        timer?.invalidate()  // ⚠️ Always invalidate before creating a new timer — prevents stacking
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        let snapPrev  = prevLiveJobs
        let snapCache = completedCache

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }

            // ── Runners
            var allRunners: [Runner] = []
            for scope in ScopeStore.shared.scopes {
                allRunners.append(contentsOf: fetchRunners(for: scope))
            }
            let metrics = allWorkerMetrics()
            var busy = allRunners.filter { $0.busy }
            var idle = allRunners.filter { !$0.busy }
            for i in busy.indices { busy[i].metrics = i < metrics.count ? metrics[i] : nil }
            for i in idle.indices {
                let s = busy.count + i
                idle[i].metrics = s < metrics.count ? metrics[s] : nil
            }
            let enrichedRunners = busy + idle

            // ── Fetch jobs
            var allFetched: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes {
                allFetched.append(contentsOf: fetchActiveJobs(for: scope))
            }

            let liveJobs  = allFetched.filter { $0.conclusion == nil }
            let freshDone = allFetched.filter { $0.conclusion != nil }
            let liveIDs   = Set(liveJobs.map { $0.id })
            let now       = Date()

            var newCache = snapCache

            // ⚠️ CALLSITE 2 of 3 — Vanished jobs: were live last poll, gone now.
            // Freeze with last known data. completedAt defaults to now if API had none.
            for (id, job) in snapPrev where !liveIDs.contains(id) {
                guard newCache[id] == nil else { continue }
                newCache[id] = ActiveJob(
                    id:          job.id,
                    name:        job.name,
                    status:      "completed",
                    conclusion:  job.conclusion ?? "success",
                    startedAt:   job.startedAt,
                    createdAt:   job.createdAt,
                    completedAt: job.completedAt ?? now,
                    htmlUrl:     job.htmlUrl,
                    isDimmed:    true
                )
            }

            // ⚠️ CALLSITE 3 of 3 — Fresh done: jobs with a conclusion inside active runs.
            // Overwrite cache entry with real conclusion data from the API.
            for job in freshDone {
                newCache[job.id] = ActiveJob(
                    id:          job.id,
                    name:        job.name,
                    status:      "completed",
                    conclusion:  job.conclusion,
                    startedAt:   job.startedAt,
                    createdAt:   job.createdAt,
                    completedAt: job.completedAt ?? now,
                    htmlUrl:     job.htmlUrl,
                    isDimmed:    true
                )
            }

            // Trim to newest 3
            if newCache.count > 3 {
                let sorted = newCache.values
                    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                newCache = Dictionary(
                    uniqueKeysWithValues: sorted.prefix(3).map { ($0.id, $0) }
                )
            }

            let newPrevLive = Dictionary(uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })

            // Display order: in_progress → queued → done (newest first), max 3 total
            let inProgress = liveJobs.filter { $0.status == "in_progress" }
            let queued     = liveJobs.filter { $0.status == "queued" }
            let cached     = newCache.values
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

            var display: [ActiveJob] = []
            for job in inProgress where display.count < 3 { display.append(job) }
            for job in queued     where display.count < 3 { display.append(job) }
            for job in cached     where display.count < 3 { display.append(job) }

            log("RunnerStore › \(inProgress.count) in_progress \(queued.count) queued | " +
                "cache: \(newCache.count) | display: \(display.count)")

            DispatchQueue.main.async {
                self.runners        = enrichedRunners
                self.jobs           = display
                self.completedCache = newCache
                self.prevLiveJobs   = newPrevLive
                self.onChange?()
            }
        }
    }
}
