import Foundation
import AppKit

enum AggregateStatus {
    case allOnline
    case someOffline
    case allOffline

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

    /// Persists completed jobs across polls keyed by job id.
    /// Jobs are added here when they disappear from the active list.
    /// Value is a frozen dimmed copy with completedAt set.
    private var completedCache: [Int: ActiveJob] = [:]

    /// Active job IDs seen in the previous poll cycle.
    private var prevActiveIDs: Set<Int> = []
    /// Previous active jobs by id — needed to build frozen copies.
    private var prevActiveMap: [Int: ActiveJob] = [:]

    private var timer: Timer?
    var onChange: (() -> Void)?

    var aggregateStatus: AggregateStatus {
        guard !runners.isEmpty else { return .allOffline }
        let onlineCount = runners.filter { $0.status == "online" }.count
        if onlineCount == runners.count { return .allOnline }
        if onlineCount == 0             { return .allOffline }
        return .someOffline
    }

    func start() {
        log("RunnerStore › start — poll interval 30s")
        timer?.invalidate()
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        log("RunnerStore › fetch — \(ScopeStore.shared.scopes.count) scope(s)")
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }

            // Snapshot previous cycle state on main thread
            let (snapshotPrevIDs, snapshotPrevMap, snapshotCache): (Set<Int>, [Int: ActiveJob], [Int: ActiveJob]) =
                DispatchQueue.main.sync {
                    (self.prevActiveIDs, self.prevActiveMap, self.completedCache)
                }

            // ── Runners ──────────────────────────────────────────
            var all: [Runner] = []
            for scope in ScopeStore.shared.scopes {
                all.append(contentsOf: fetchRunners(for: scope))
            }
            let workerMetrics = allWorkerMetrics()
            var busyRunners = all.filter {  $0.busy }
            var idleRunners = all.filter { !$0.busy }
            for i in busyRunners.indices {
                busyRunners[i].metrics = i < workerMetrics.count ? workerMetrics[i] : nil
            }
            let offset = busyRunners.count
            for i in idleRunners.indices {
                idleRunners[i].metrics = (offset + i) < workerMetrics.count ? workerMetrics[offset + i] : nil
            }
            let enriched = busyRunners + idleRunners

            // ── Active jobs ───────────────────────────────────────
            var fetched: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes {
                fetched.append(contentsOf: fetchActiveJobs(for: scope))
            }
            // Sort: in_progress first, queued second
            fetched.sort { jobRank($0) < jobRank($1) }
            let currentActiveIDs = Set(fetched.map { $0.id })
            let currentActiveMap = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })

            // ── Update completed cache ─────────────────────────────
            // Jobs that were active last poll but gone now → freeze into cache
            var newCache = snapshotCache
            let now = Date()
            for id in snapshotPrevIDs where !currentActiveIDs.contains(id) {
                guard newCache[id] == nil, let prev = snapshotPrevMap[id] else { continue }
                newCache[id] = ActiveJob(
                    id:          prev.id,
                    name:        prev.name,
                    status:      "completed",
                    conclusion:  "success",
                    startedAt:   prev.startedAt,
                    createdAt:   prev.createdAt,
                    completedAt: now,
                    isDimmed:    true
                )
            }
            // Remove from cache any job that is active again (re-run)
            for id in currentActiveIDs { newCache.removeValue(forKey: id) }

            // ── Build final list (max 3) ───────────────────────────
            let active = Array(fetched.prefix(3))
            let remaining = 3 - active.count
            var cached: [ActiveJob] = []
            if remaining > 0 {
                // Sort cache newest completedAt first
                cached = newCache.values
                    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                    .prefix(remaining)
                    .map { $0 }
            }
            let merged = active + cached

            log("RunnerStore › \(enriched.count) runner(s) | \(active.count) active + \(cached.count) cached = \(merged.count) job(s) | cache size: \(newCache.count)")

            DispatchQueue.main.async {
                self.runners        = enriched
                self.jobs           = merged
                self.completedCache = newCache
                self.prevActiveIDs  = currentActiveIDs
                self.prevActiveMap  = currentActiveMap
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
