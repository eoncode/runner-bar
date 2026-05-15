import SwiftUI

// MARK: - SystemStatsViewModel

/// `ObservableObject` that drives `PopoverHeaderView` with live CPU, memory,
/// and disk stats plus rolling sparkline history arrays.
final class SystemStatsViewModel: ObservableObject {
    /// Latest combined snapshot — bound directly into `PopoverHeaderView`.
    @Published var stats = SystemStats.zero
    /// Rolling CPU usage history (0–1 normalised), newest last.
    @Published var cpuHistory: [Double] = []
    /// Rolling memory usage history (0–1 normalised), newest last.
    @Published var memHistory: [Double] = []
    /// Rolling disk usage history (0–1 normalised), newest last.
    @Published var diskHistory: [Double] = []

    private let maxHistory = 60
    private var pollerToken: Int?
    private var diskTimer: Timer?

    // MARK: - Lifecycle

    /// Starts the CPU/memory poller and schedules a periodic disk check.
    func start() {
        guard pollerToken == nil else { return }
        pollerToken = SystemStatsPoller.shared.addObserver { [weak self] snapshot in
            self?.apply(snapshot: snapshot)
        }
        SystemStatsPoller.shared.start(interval: 5)
        refreshDisk()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshDisk()
        }
    }

    /// Stops all active polling. Call when the popover panel closes.
    func stop() {
        pollerToken = nil
        diskTimer?.invalidate()
        diskTimer = nil
    }

    // MARK: - Private

    private func apply(snapshot: SystemStatsSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stats.cpuPct = snapshot.cpuPercent
            self.stats.memUsedGB = snapshot.memPercent
            self.stats.memTotalGB = 100
            self.appendHistory(value: snapshot.cpuPercent / 100, to: &self.cpuHistory)
            self.appendHistory(value: snapshot.memPercent / 100, to: &self.memHistory)
        }
    }

    private func refreshDisk() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (used, total) = Self.diskUsage()
            DispatchQueue.main.async {
                guard let self else { return }
                self.stats.diskUsedGB = used
                self.stats.diskTotalGB = total
                let pct = total > 0 ? used / total : 0
                self.appendHistory(value: pct, to: &self.diskHistory)
            }
        }
    }

    private func appendHistory(value: Double, to array: inout [Double]) {
        array.append(value)
        if array.count > maxHistory { array.removeFirst(array.count - maxHistory) }
    }

    /// Returns (usedGB, totalGB) for the root volume via `df -k /`.
    private static func diskUsage() -> (Double, Double) {
        let output = shell("df -k / | tail -1", timeout: 5)
        let parts = output.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4,
              let total1k = Double(parts[1]),
              let used1k  = Double(parts[2])
        else { return (0, 0) }
        let gb = 1_048_576.0
        return (used1k / gb, total1k / gb)
    }
}
