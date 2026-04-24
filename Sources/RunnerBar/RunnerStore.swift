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
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        log("RunnerStore › fetch — \(ScopeStore.shared.scopes.count) scope(s)")
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }

            // ── Runners ──────────────────────────────────────────────
            var all: [Runner] = []
            for scope in ScopeStore.shared.scopes {
                log("RunnerStore › fetching runners for scope: \(scope)")
                let fetched = fetchRunners(for: scope)
                log("RunnerStore › scope \(scope) → \(fetched.count) runner(s)")
                all.append(contentsOf: fetched)
            }

            // Assign Worker process metrics by slot index (busy-first)
            let workerMetrics = allWorkerMetrics()
            log("RunnerStore › found \(workerMetrics.count) worker process(es)")
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
            log("RunnerStore › \(enriched.count) runner(s) enriched")

            // ── Active Jobs ──────────────────────────────────────────
            var allJobs: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes {
                log("RunnerStore › fetching jobs for scope: \(scope)")
                allJobs.append(contentsOf: fetchActiveJobs(for: scope))
            }
            // Cap at 5, always show at least what exists (down to 0)
            let topJobs = Array(allJobs.prefix(5))
            log("RunnerStore › fetch complete — \(enriched.count) runner(s), \(topJobs.count) job(s)")

            DispatchQueue.main.async {
                self.runners = enriched
                self.jobs    = topJobs
                self.onChange?()
            }
        }
    }
}
