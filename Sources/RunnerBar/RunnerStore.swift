import Foundation
import AppKit

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

final class RunnerStore {
    static let shared = RunnerStore()

    private(set) var runners: [Runner] = []
    private(set) var jobs: [ActiveJob] = []

    /// Persists completed jobs keyed by job id.
    /// Never cleared between polls — only grows (or removes re-activated jobs).
    private var completedCache: [Int: ActiveJob] = [:]

    private var timer: Timer?
    var onChange: (() -> Void)?

    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let n = runners.filter { $0.status == "online" }.count
        if n == runners.count { return .allOnline }
        if n == 0             { return .allOffline }
        return .someOffline
    }

    func start() {
        log("RunnerStore › start")
        timer?.invalidate()
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.fetch() }
    }

    func fetch() {
        log("RunnerStore › fetch")
        let snapCache: [Int: ActiveJob] = DispatchQueue.main.sync { self.completedCache }

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }

            // ── Runners
            var all: [Runner] = []
            for scope in ScopeStore.shared.scopes { all.append(contentsOf: fetchRunners(for: scope)) }
            let metrics = allWorkerMetrics()
            var busy = all.filter { $0.busy }; var idle = all.filter { !$0.busy }
            for i in busy.indices { busy[i].metrics = i < metrics.count ? metrics[i] : nil }
            for i in idle.indices { let s = busy.count + i; idle[i].metrics = s < metrics.count ? metrics[s] : nil }
            let enriched = busy + idle

            // ── All jobs from active runs (includes just-finished with conclusion != nil)
            var allFetched: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes { allFetched.append(contentsOf: fetchActiveJobs(for: scope)) }

            // Split active vs just-finished
            let activeJobs  = allFetched.filter { $0.conclusion == nil }.sorted { jobRank($0) < jobRank($1) }
            let finishedNow = allFetched.filter { $0.conclusion != nil }
            let activeIDs   = Set(activeJobs.map { $0.id })

            // ── Update cache
            var newCache = snapCache
            let now = Date()
            for job in finishedNow {
                guard newCache[job.id] == nil else { continue }
                newCache[job.id] = ActiveJob(
                    id: job.id, name: job.name, status: "completed",
                    conclusion: job.conclusion,
                    startedAt: job.startedAt, createdAt: job.createdAt,
                    completedAt: job.completedAt ?? now,
                    isDimmed: true
                )
            }
            // Re-activated jobs leave the cache
            for id in activeIDs { newCache.removeValue(forKey: id) }

            // ── Build final list: active first (max 3), pad with cached completed
            let active    = Array(activeJobs.prefix(3))
            let remaining = 3 - active.count
            var cached: [ActiveJob] = []
            if remaining > 0 {
                cached = newCache.values
                    .filter { !activeIDs.contains($0.id) }
                    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                    .prefix(remaining)
                    .map { $0 }
            }
            let merged = active + cached

            log("RunnerStore › \(enriched.count) runners | \(active.count) active + \(cached.count) cached = \(merged.count) shown | cache: \(newCache.count)")

            DispatchQueue.main.async {
                self.runners        = enriched
                self.jobs           = merged
                self.completedCache = newCache
                self.onChange?()
            }
        }
    }
}

func jobRank(_ job: ActiveJob) -> Int {
    switch job.status {
    case "in_progress": return 0
    case "queued":      return 1
    default:            return 2
    }
}
