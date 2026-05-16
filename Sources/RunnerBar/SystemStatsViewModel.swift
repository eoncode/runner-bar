import Combine
import Foundation

/// ViewModel that drives SystemStatsView with periodic system-stats sampling.
final class SystemStatsViewModel: ObservableObject {
    @Published var stats = SystemStats()
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []

    private var timer: Timer?
    private let maxHistory = 30
    private let poller = SystemStatsPoller()

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let s = self.poller.poll()
            DispatchQueue.main.async {
                self.stats = s
                self.cpuHistory.append(s.cpuPct / 100.0)
                self.memHistory.append(s.memTotalGB > 0 ? s.memUsedGB / s.memTotalGB : 0)
                if self.cpuHistory.count > self.maxHistory { self.cpuHistory.removeFirst() }
                if self.memHistory.count > self.maxHistory { self.memHistory.removeFirst() }
            }
        }
    }
}
