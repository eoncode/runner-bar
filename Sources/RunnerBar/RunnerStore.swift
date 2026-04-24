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
    /// Last active (non-dimmed) jobs seen — used to seed completed tail
    /// when they vanish before the GitHub API marks the run as completed.
    private var lastActiveJobs: [ActiveJob] = []
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

            // ── Snapshot previous active jobs (main-thread safe read before bg work)
            let prevActive: [ActiveJob] = DispatchQueue.main.sync { self.lastActiveJobs }

            // ── Runners ──────────────────────────────────────────────
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
                let slot = offset + i
                idleRunners[i].metrics = slot < workerMetrics.count ? workerMetrics[slot] : nil
            }
            let enriched = busyRunners + idleRunners

            // ── Active jobs ──────────────────────────────────────────
            var activeJobs: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes {
                activeJobs.append(contentsOf: fetchActiveJobs(for: scope))
            }

            // ── Completed tail ────────────────────────────────────
            var completedTail: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes {
                completedTail.append(contentsOf: fetchRecentCompletedJobs(for: scope))
            }

            // Build tail: prefer fresh API data.
            // If API returned nothing (lag), fall back to:
            //   1. Previous dimmed jobs already in self.jobs
            //   2. Previous active jobs frozen as dimmed right now
            let now = Date()
            let tail: [ActiveJob]
            if !completedTail.isEmpty {
                tail = Array(completedTail.prefix(3))
            } else {
                // Try existing dimmed jobs first
                let existingDimmed = DispatchQueue.main.sync { self.jobs.filter { $0.isDimmed } }
                if !existingDimmed.isEmpty {
                    tail = existingDimmed
                } else if !prevActive.isEmpty {
                    // Active jobs just vanished — freeze them as dimmed tail
                    tail = Array(prevActive.map { job in
                        ActiveJob(
                            id:          job.id,
                            name:        job.name,
                            status:      "completed",
                            conclusion:  "success",
                            startedAt:   job.startedAt,
                            createdAt:   job.createdAt,
                            completedAt: now,
                            isDimmed:    true
                        )
                    }.prefix(3))
                } else {
                    tail = []
                }
            }

            let merged = Array((activeJobs + tail).prefix(3))

            log("RunnerStore › fetch complete — \(enriched.count) runner(s), \(merged.count) job(s) (\(activeJobs.count) active, \(tail.count) tail)")

            DispatchQueue.main.async {
                self.runners = enriched
                self.jobs    = merged
                // Track active jobs for next cycle's fallback
                self.lastActiveJobs = activeJobs
                self.onChange?()
            }
        }
    }
}
