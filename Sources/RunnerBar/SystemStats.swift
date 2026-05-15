// swiftlint:disable missing_docs
// swiftlint:disable all
import Darwin
import Foundation

/// System resource snapshot.
struct SystemStats: Equatable {
    /// CPU usage percentage.
    var cpuPct: Double = 0
    /// Used RAM in GB.
    var memUsedGB: Double = 0
    /// Total RAM in GB.
    var memTotalGB: Double = 0
    /// Used disk in GB.
    var diskUsedGB: Double = 0
    /// Total disk in GB.
    var diskTotalGB: Double = 0
}

/// Polls system resource metrics.
final class SystemStatsPoller {
    func poll() -> SystemStats {
        var stats = SystemStats()
        stats.cpuPct    = cpuUsage()
        (stats.memUsedGB, stats.memTotalGB) = memUsage()
        (stats.diskUsedGB, stats.diskTotalGB) = diskUsage()
        return stats
    }
    private func cpuUsage() -> Double {
        func sample() -> (idle: UInt64, total: UInt64) {
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            var info  = host_cpu_load_info_data_t()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return (0, 1) }
            let user   = UInt64(info.cpu_ticks.0)
            let system = UInt64(info.cpu_ticks.1)
            let idle   = UInt64(info.cpu_ticks.2)
            let nice   = UInt64(info.cpu_ticks.3)
            return (idle, user + system + idle + nice)
        }
        let first  = sample()
        Thread.sleep(forTimeInterval: 0.2)
        let second     = sample()
        let deltaIdle  = second.idle  - first.idle
        let deltaTotal = second.total - first.total
        guard deltaTotal > 0 else { return 0 }
        return (1.0 - Double(deltaIdle) / Double(deltaTotal)) * 100.0
    }
    private func memUsage() -> (used: Double, total: Double) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let pageSize   = UInt64(vm_page_size)
        let used       = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total      = UInt64(ProcessInfo.processInfo.physicalMemory)
        let gb: Double = 1_073_741_824
        return (Double(used) / gb, Double(total) / gb)
    }
    private func diskUsage() -> (used: Double, total: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let totalBytes = attrs[.systemSize] as? Int64,
              let freeBytes  = attrs[.systemFreeSize] as? Int64 else { return (0, 0) }
        let gb    = 1_073_741_824.0
        let total = Double(totalBytes) / gb
        return (total - Double(freeBytes) / gb, total)
    }
}
