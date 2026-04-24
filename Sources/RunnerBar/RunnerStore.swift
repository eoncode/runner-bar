import Foundation
import AppKit

enum AggregateStatus {
    case allOnline
    case someOffline
    case allOffline

    var dot: String {
        switch self {
        case .allOnline:  return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
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

            // Fetch runners from GitHub API
            var all: [Runner] = []
            for scope in ScopeStore.shared.scopes {
                log("RunnerStore › fetching scope: \(scope)")
                let fetched = fetchRunners(for: scope)
                log("RunnerStore › scope \(scope) → \(fetched.count) runner(s)")
                all.append(contentsOf: fetched)
            }

            // Collect Worker process metrics once, sorted by CPU desc
            // Mirrors ci-dash.py pair_runners(): busy runners first, then idle
            let workerMetrics = allWorkerMetrics()
            log("RunnerStore › found \(workerMetrics.count) worker process(es)")

            // Sort runners: busy (active) first, then idle — same ordering
            // assumption as ci-dash which pairs worker[0] with the busiest runner
            var busyRunners  = all.filter { $0.busy }
            var idleRunners  = all.filter { !$0.busy }

            // Assign metrics by slot index
            for i in busyRunners.indices {
                busyRunners[i].metrics = i < workerMetrics.count ? workerMetrics[i] : nil
            }
            let offset = busyRunners.count
            for i in idleRunners.indices {
                let slot = offset + i
                idleRunners[i].metrics = slot < workerMetrics.count ? workerMetrics[slot] : nil
            }

            let enriched = busyRunners + idleRunners
            log("RunnerStore › fetch complete — \(enriched.count) runner(s)")

            DispatchQueue.main.async {
                self.runners = enriched
                self.onChange?()
            }
        }
    }
}
