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
    private(set) var jobs: [ActiveJob] = []  // max 3, shown in UI

    // Persistent completed tail — never wiped, only updated.
    // Seeded on first launch from API. After that, jobs that finish
    // are frozen in here immediately (no API lag gap).
    private var completedTail: [ActiveJob] = []

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
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.fetch() }
    }

    func fetch() {
        log("RunnerStore › fetch")
        let snapTail = completedTail

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

            // ── Fetch all jobs from active runs
            // fetchActiveJobs returns all jobs (active + just-completed) from
            // in_progress/queued runs — we split them here.
            var allFetched: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes { allFetched.append(contentsOf: fetchActiveJobs(for: scope)) }

            // Active = no conclusion yet. Sorted in_progress → queued.
            let activeJobs = allFetched
                .filter { $0.conclusion == nil }
                .sorted { rankJob($0) < rankJob($1) }

            // Done within this run = has conclusion. Mark dimmed.
            let freshDone: [ActiveJob] = allFetched
                .filter { $0.conclusion != nil }
                .map { j in
                    var d = j; d.isDimmed = true; return d
                }

            // ── Update completed tail
            // Merge freshDone + existing tail, dedupe by id, cap 3.
            // If no fresh done jobs this cycle, keep tail unchanged.
            let newTail: [ActiveJob]
            if !freshDone.isEmpty {
                var merged = freshDone
                for job in snapTail where !merged.contains(where: { $0.id == job.id }) {
                    merged.append(job)
                }
                newTail = Array(merged.prefix(3))
            } else {
                newTail = snapTail
            }

            // ── Display: active first, then tail, cap 3
            let display = Array((activeJobs + newTail).prefix(3))

            log("RunnerStore › done — \(enriched.count) runners, \(activeJobs.count) active, \(newTail.count) tail, \(display.count) shown")

            DispatchQueue.main.async {
                self.runners       = enriched
                self.jobs          = display
                self.completedTail = newTail
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
