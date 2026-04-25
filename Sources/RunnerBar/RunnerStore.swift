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
    private(set) var jobs: [ActiveJob] = []  // what UI shows, max 3

    private var prevLiveJobs: [Int: ActiveJob] = [:]

    /// Persisted completed jobs, keyed by ID. Never cleared mid-session.
    /// Only mutated on the main thread to avoid stale-snapshot races.
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
        timer?.invalidate()
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        let snapPrev = prevLiveJobs

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

            // ── Fetch live jobs
            var allFetched: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes {
                allFetched.append(contentsOf: fetchActiveJobs(for: scope))
            }

            let liveJobs  = allFetched.filter { $0.conclusion == nil }
            let freshDone = allFetched.filter { $0.conclusion != nil }
            let liveIDs   = Set(liveJobs.map { $0.id })
            let now       = Date()

            // ── Compute new done entries
            var newDoneEntries: [Int: ActiveJob] = [:]
            for (id, job) in snapPrev where !liveIDs.contains(id) {
                newDoneEntries[id] = ActiveJob(
                    id: job.id, runID: job.runID, name: job.name,
                    status: "completed",
                    conclusion: job.conclusion ?? "success",
                    startedAt: job.startedAt, createdAt: job.createdAt,
                    completedAt: job.completedAt ?? now,
                    isDimmed: true
                )
            }
            for job in freshDone {
                newDoneEntries[job.id] = ActiveJob(
                    id: job.id, runID: job.runID, name: job.name,
                    status: "completed",
                    conclusion: job.conclusion,
                    startedAt: job.startedAt, createdAt: job.createdAt,
                    completedAt: job.completedAt ?? now,
                    isDimmed: true
                )
            }

            let newPrevLive = Dictionary(uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })
            let inProgress  = liveJobs.filter { $0.status == "in_progress" }
            let queued      = liveJobs.filter { $0.status == "queued" }

            log("RunnerStore › \(inProgress.count) in_progress \(queued.count) queued | vanished: \(newDoneEntries.count)")

            DispatchQueue.main.async {
                for (id, job) in newDoneEntries {
                    self.completedCache[id] = job
                }
                if self.completedCache.count > 3 {
                    let sorted = self.completedCache.values
                        .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                    self.completedCache = Dictionary(
                        uniqueKeysWithValues: sorted.prefix(3).map { ($0.id, $0) }
                    )
                }

                let cached = self.completedCache.values
                    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

                var display: [ActiveJob] = []
                for job in inProgress where display.count < 3 { display.append(job) }
                for job in queued     where display.count < 3 { display.append(job) }
                for job in cached     where display.count < 3 { display.append(job) }

                log("RunnerStore › display: \(display.count) | cache: \(self.completedCache.count)")

                self.runners      = enrichedRunners
                self.jobs         = display
                self.prevLiveJobs = newPrevLive
                self.onChange?()
            }
        }
    }
}

private func rankJob(_ job: ActiveJob) -> Int {
    switch job.status {
    case "in_progress": return 0
    case "queued":      return 1
    default:            return 2
    }
}
