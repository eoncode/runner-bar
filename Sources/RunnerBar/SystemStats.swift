// swiftlint:disable missing_docs
import Darwin
import Foundation

// MARK: - SystemStats
struct SystemStats: Equatable {
    var cpuPct: Double = 0
    var memUsedGB: Double = 0
    var memTotalGB: Double = 0
    var diskUsedGB: Double = 0
    var diskTotalGB: Double = 0
}

// MARK: - SystemStatsPoller
final class SystemStatsPoller {
    func poll() -> SystemStats {
        var stats = SystemStats()
        stats.cpuPct    = cpuUsage()
        (stats.memUsedGB, stats.memTotalGB) = memUsage()
        (stats.diskUsedGB, stats.diskTotalGB) = diskUsage()
        return stats
    }

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
        let first  = sample()
        prevIdle   = first.idle
        prevTotal  = first.total
        Thread.sleep(forTimeInterval: 0.2)
        let second     = sample()
        let deltaIdle  = second.idle  - prevIdle
        let deltaTotal = second.total - prevTotal
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
        let active     = UInt64(stats.active_count)          * pageSize
        let wired      = UInt64(stats.wire_count)            * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used       = active + wired + compressed
        let total      = UInt64(ProcessInfo.processInfo.physicalMemory)
        let gb: Double = 1_073_741_824
        return (Double(used) / gb, Double(total) / gb)
    }

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
// swiftlint:enable missing_docs
