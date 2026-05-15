import Foundation

// MARK: - SystemStats

/// A snapshot of current system resource usage.
struct SystemStats {
    /// CPU utilisation percentage (0–100).
    var cpuPct: Double = 0
    /// Amount of RAM currently in use, in gigabytes.
    var memUsedGB: Double = 0
    /// Total installed RAM, in gigabytes.
    var memTotalGB: Double = 0
    /// Amount of disk space currently used, in gigabytes.
    var diskUsedGB: Double = 0
    /// Total disk capacity, in gigabytes.
    var diskTotalGB: Double = 0
}

// MARK: - SystemStatsViewModel

/// Observable view-model that polls system stats every 2 seconds.
/// Stopped while the popover is open to avoid spurious SwiftUI re-renders.
final class SystemStatsViewModel: ObservableObject {
    /// Latest system stats snapshot, published to SwiftUI.
    @Published var stats = SystemStats()
    /// Rolling history of CPU samples (0–1 fractions), newest last.
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    /// Rolling history of memory-usage samples (0–1 fractions), newest last.
    @Published var memHistory: [Double] = Array(repeating: 0, count: 30)
    /// Rolling history of disk-usage samples (0–1 fractions), newest last.
    @Published var diskHistory: [Double] = Array(repeating: 0, count: 30)

    private var timer: Timer?

    /// Starts the 2-second polling timer.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Stops the polling timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let cpu = cpuUsage()
        let mem = memUsage()
        let disk = diskUsage()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stats = SystemStats(
                cpuPct: cpu * 100,
                memUsedGB: mem.used,
                memTotalGB: mem.total,
                diskUsedGB: disk.used,
                diskTotalGB: disk.total
            )
            self.cpuHistory = Array((self.cpuHistory + [cpu]).suffix(30))
            let memFrac = mem.total > 0 ? mem.used / mem.total : 0
            self.memHistory = Array((self.memHistory + [memFrac]).suffix(30))
            let diskFrac = disk.total > 0 ? disk.used / disk.total : 0
            self.diskHistory = Array((self.diskHistory + [diskFrac]).suffix(30))
        }
    }
}

// MARK: - CPU

private func cpuUsage() -> Double {
    var cpuInfo: processor_info_array_t?
    var numCpuInfo: mach_msg_type_number_t = 0
    var numCpus: natural_t = 0
    let result = host_processor_info(
        mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
        &numCpus, &cpuInfo, &numCpuInfo
    )
    guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }
    var totalUser: Int32 = 0; var totalSystem: Int32 = 0
    var totalIdle: Int32 = 0; var totalNice: Int32 = 0
    for i in 0 ..< Int(numCpus) {
        // swiftlint:disable:next identifier_name
        let base = Int32(CPU_STATE_MAX) * Int32(i)
        totalUser   += info[Int(base + CPU_STATE_USER)]
        totalSystem += info[Int(base + CPU_STATE_SYSTEM)]
        totalIdle   += info[Int(base + CPU_STATE_IDLE)]
        totalNice   += info[Int(base + CPU_STATE_NICE)]
    }
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCpuInfo) * 4)
    let total = totalUser + totalSystem + totalIdle + totalNice
    guard total > 0 else { return 0 }
    return Double(totalUser + totalSystem + totalNice) / Double(total)
}

// MARK: - Memory

private struct MemUsage { let used, total: Double }

private func memUsage() -> MemUsage {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return MemUsage(used: 0, total: 0) }
    let pageSize = Double(vm_kernel_page_size)
    let active   = Double(stats.active_count)   * pageSize
    let wired    = Double(stats.wire_count)      * pageSize
    let compressed = Double(stats.compressor_page_count) * pageSize
    let used  = (active + wired + compressed) / 1_073_741_824
    let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    return MemUsage(used: used, total: total)
}

// MARK: - Disk

private struct DiskUsage { let used, total: Double }

private func diskUsage() -> DiskUsage {
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
          let totalBytes = attrs[.systemSize] as? Int64,
          let freeBytes  = attrs[.systemFreeSize] as? Int64
    else { return DiskUsage(used: 0, total: 0) }
    let gb: Double = 1_073_741_824
    let total = Double(totalBytes) / gb
    let free  = Double(freeBytes)  / gb
    return DiskUsage(used: total - free, total: total)
}
