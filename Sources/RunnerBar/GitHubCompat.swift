// swiftlint:disable missing_docs identifier_name
import Foundation
import Combine
import SwiftUI

// MARK: - SystemStats compatibility shims

/// Legacy struct alias — maps to the new SystemStatsSnapshot.
typealias SystemStats = SystemStatsSnapshot

extension SystemStatsSnapshot {
    /// CPU usage percentage (0–100).
    var cpuUsage: Double { cpuPercent }
    /// Memory usage percentage (0–100).
    var memUsage: Double { memPercent }
    /// Disk used percentage — approximated via `df /`.
    var diskUsedPct: Double { SystemStatsViewModel.lastDiskUsedPct }
    /// Disk free percentage.
    var diskFreePct: Double { max(0, 100 - diskUsedPct) }
}

/// ObservableObject wrapper that the popover views depend on.
final class SystemStatsViewModel: ObservableObject {
    @Published var stats: SystemStatsSnapshot = SystemStatsSnapshot(cpuPercent: 0, memPercent: 0)
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var memHistory: [Double] = Array(repeating: 0, count: 30)
    @Published var diskHistory: [Double] = Array(repeating: 0, count: 30)

    /// Cached last disk-used pct so the extension property can read it.
    static var lastDiskUsedPct: Double = 0

    private var observerToken: Int?

    /// Starts polling system stats and forwarding updates to published properties.
    func start() {
        SystemStatsPoller.shared.start()
        observerToken = SystemStatsPoller.shared.addObserver { [weak self] snapshot in
            guard let self else { return }
            let disk = Self.fetchDiskUsedPct()
            Self.lastDiskUsedPct = disk
            self.stats = snapshot
            self.cpuHistory = Array((self.cpuHistory + [snapshot.cpuPercent]).suffix(30))
            self.memHistory = Array((self.memHistory + [snapshot.memPercent]).suffix(30))
            self.diskHistory = Array((self.diskHistory + [disk]).suffix(30))
        }
    }

    /// Stops polling (no-op — SystemStatsPoller runs indefinitely).
    func stop() {}

    // MARK: - Disk usage

    private static func fetchDiskUsedPct() -> Double {
        let output = shell("df / | tail -1", timeout: 3)
        let cols = output.split(separator: " ").map(String.init)
        if let cap = cols.first(where: { $0.hasSuffix("%") }),
           let val = Double(cap.dropLast()) {
            return val
        }
        if cols.count >= 4,
           let used = Double(cols[2]),
           let avail = Double(cols[3]),
           used + avail > 0 {
            return (used / (used + avail)) * 100
        }
        return 0
    }
}
// swiftlint:enable missing_docs identifier_name
