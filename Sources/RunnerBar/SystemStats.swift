import Foundation

/// Snapshot of CPU and memory metrics sampled at a point in time.
struct SystemStats {
    /// CPU usage as a fraction in 0…100 (percentage).
    var cpuPct: Double
    /// Used memory in gigabytes.
    var memUsedGB: Double
    /// Total physical memory in gigabytes.
    var memTotalGB: Double
    /// Used disk space in gigabytes.
    var diskUsedGB: Double
    /// Total disk space in gigabytes.
    var diskTotalGB: Double

    /// Memory pressure as a fraction in 0…1.
    var memoryPressure: Double {
        guard memTotalGB > 0 else { return 0 }
        return memUsedGB / memTotalGB
    }

    /// Disk usage as a fraction in 0…1.
    var diskPressure: Double {
        guard diskTotalGB > 0 else { return 0 }
        return diskUsedGB / diskTotalGB
    }

    /// Zero-initialised snapshot used as the default before the first sample arrives.
    static let zero = SystemStats(
        cpuPct: 0, memUsedGB: 0, memTotalGB: 0, diskUsedGB: 0, diskTotalGB: 0
    )
}
