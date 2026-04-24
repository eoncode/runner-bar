import Foundation
import AppKit

enum AggregateStatus {
    case allOnline
    case someOffline
    case allOffline

    var dot: String {
        switch self {
        case .allOnline: return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }

    var symbolName: String {
        switch self {
        case .allOnline: return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
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
        if onlineCount == 0 { return .allOffline }
        return .someOffline
    }

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func fetch() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            var all: [Runner] = []
            for scope in ScopeStore.shared.scopes {
                all.append(contentsOf: fetchRunners(for: scope))
            }
            // Inject busyCount so each runner knows how many peers are active
            let busyCount = max(all.filter { $0.busy }.count, 1)
            let enriched = all.map { runner -> Runner in
                var r = runner
                r.busyCount = busyCount
                return r
            }
            DispatchQueue.main.async {
                self.runners = enriched
                self.onChange?()
            }
        }
    }
}
