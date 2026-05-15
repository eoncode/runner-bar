import Foundation
import Combine
import SwiftUI

// MARK: - SystemStats compatibility shims
// The views were written against a `SystemStats` struct + `SystemStatsViewModel`
// ObservableObject. The new SystemStats.swift renamed these to
// SystemStatsSnapshot + SystemStatsPoller. These shims restore the old API.

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
    func stop() {
        // SystemStatsPoller runs indefinitely; nothing to stop.
    }

    // MARK: - Disk usage

    private static func fetchDiskUsedPct() -> Double {
        let output = shell("df / | tail -1", timeout: 3)
        let cols = output.split(separator: " ").map(String.init)
        // df columns: Filesystem 512-Blk-Used Available Capacity ...
        // Capacity column contains e.g. "42%"
        if let cap = cols.first(where: { $0.hasSuffix("%") }),
           let val = Double(cap.dropLast()) {
            return val
        }
        // Fallback: use 1K-blocks columns (col index 2=used, 3=avail)
        if cols.count >= 4,
           let used = Double(cols[2]),
           let avail = Double(cols[3]),
           used + avail > 0 {
            return (used / (used + avail)) * 100
        }
        return 0
    }
}
