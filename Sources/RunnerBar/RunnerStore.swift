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

    // Never cleared. Populated two ways:
    // 1. On first launch: seeded from most recent completed API run.
    // 2. Every poll: jobs that were active last cycle but gone now
    //    are frozen here immediately (beats API lag every time).
    private var completedTail: [ActiveJob] = []
    private var prevActiveJobs: [ActiveJob] = []  // snapshot from last poll

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
        // Capture main-thread state before going async
        let snapTail = completedTail
        let snapPrev = prevActiveJobs

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

            // ── Active jobs this cycle (in_progress + queued runs only)
            var activeJobs: [ActiveJob] = []
            for scope in ScopeStore.shared.scopes { activeJobs.append(contentsOf: fetchActiveJobs(for: scope)) }
            let activeJobs_sorted = activeJobs
                .filter { $0.conclusion == nil }
                .sorted { rankJob($0) < rankJob($1) }
            let activeIDs = Set(activeJobs_sorted.map { $0.id })

            // ── Detect vanished jobs: active last poll, gone this poll.
            // GitHub moves completed jobs off in_progress/queued endpoints
            // immediately — freeze them into tail before API lag catches up.
            let now = Date()
            let vanished: [ActiveJob] = snapPrev
                .filter { !activeIDs.contains($0.id) }
                .map { job in
                    ActiveJob(
                        id: job.id, name: job.name,
                        status: "completed", conclusion: "success",
                        startedAt: job.startedAt, createdAt: job.createdAt,
                        completedAt: now, isDimmed: true
                    )
                }

            // ── Build new tail: vanished jobs prepended, deduped, capped at 3.
            // If nothing vanished, keep existing tail unchanged.
            let newTail: [ActiveJob]
            if !vanished.isEmpty {
                var merged = vanished
                for job in snapTail where !merged.contains(where: { $0.id == job.id }) {
                    merged.append(job)
                }
                newTail = Array(merged.prefix(3))
            } else {
                newTail = snapTail
            }

            // ── Display: active first, fill with tail, cap 3
            let display = Array((activeJobs_sorted + newTail).prefix(3))

            log("RunnerStore › done — \(enriched.count) runners, \(activeJobs_sorted.count) active, \(newTail.count) tail, \(display.count) shown")

            DispatchQueue.main.async {
                self.runners        = enriched
                self.jobs           = display
                self.completedTail  = newTail
                self.prevActiveJobs = activeJobs_sorted
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
