import Foundation
import Darwin

// MARK: - SystemStats
/// A point-in-time snapshot of host-machine resource utilisation.
/// All values are polled by `SystemStatsPoller` and stored in `RunnerStoreState`.
struct SystemStats: Equatable {
    /// CPU utilisation percentage (0–100), averaged across all cores.
    var cpuPct: Double = 0
    /// Memory currently in use, in gigabytes.
    var memUsedGB: Double = 0
    /// Total physical memory, in gigabytes.
    var memTotalGB: Double = 0
    /// Disk space currently used on the boot volume, in gigabytes.
    var diskUsedGB: Double = 0
    /// Total capacity of the boot volume, in gigabytes.
    var diskTotalGB: Double = 0
}

// MARK: - SystemStatsPoller
/// Polls CPU, memory, and disk statistics from Darwin/macOS system APIs.
/// Call `poll()` on a background thread; it blocks for ~200 ms while sampling CPU.
final class SystemStatsPoller {
    /// Samples the current system stats and returns a populated `SystemStats` snapshot.
    func poll() -> SystemStats {
        var stats = SystemStats()
        stats.cpuPct    = cpuUsage()
        (stats.memUsedGB, stats.memTotalGB) = memUsage()
        (stats.diskUsedGB, stats.diskTotalGB) = diskUsage()
        return stats
    }

    // MARK: CPU
    private func cpuUsage() -> Double {
        var prevIdle: UInt64 = 0
        var prevTotal: UInt64 = 0
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
            let total  = user + system + idle + nice
            return (idle, total)
        }
        let first = sample()
        prevIdle  = first.idle
        prevTotal = first.total
        Thread.sleep(forTimeInterval: 0.2)
        let second    = sample()
        let deltaIdle = second.idle  - prevIdle
        let deltaTotal = second.total - prevTotal
        guard deltaTotal > 0 else { return 0 }
        return (1.0 - Double(deltaIdle) / Double(deltaTotal)) * 100.0
    }

    // MARK: Memory
    private func memUsage() -> (used: Double, total: Double) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let pageSize  = UInt64(vm_page_size)
        let active    = UInt64(stats.active_count)   * pageSize
        let wired     = UInt64(stats.wire_count)     * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used      = active + wired + compressed
        let total     = UInt64(ProcessInfo.processInfo.physicalMemory)
        let gb: Double = 1_073_741_824
        return (Double(used) / gb, Double(total) / gb)
    }

    // MARK: Disk
    private func diskUsage() -> (used: Double, total: Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let totalBytes = attrs[.systemSize] as? Int64,
              let freeBytes  = attrs[.systemFreeSize] as? Int64 else { return (0, 0) }
        let gb: Double = 1_073_741_824
        let total = Double(totalBytes) / gb
        let free  = Double(freeBytes)  / gb
        return (total - free, total)
    }
}
