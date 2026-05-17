import Foundation

// swiftlint:disable missing_docs

/// Snapshot of CPU and memory metrics sampled at a point in time.
struct SystemStats {
    /// CPU usage as a fraction in 0…1.
    var cpuUsage: Double
    /// Resident memory in bytes.
    var memoryUsed: UInt64
    /// Total physical memory in bytes.
    var memoryTotal: UInt64

    /// Memory pressure as a fraction in 0…1.
    var memoryPressure: Double {
        guard memoryTotal > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryTotal)
    }
}

// swiftlint:enable missing_docs
