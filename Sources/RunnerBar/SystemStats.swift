import Combine
import Darwin
import Foundation

// MARK: - SystemStats

/// A snapshot of CPU, memory, and disk metrics at a single point in time.
///
/// All values are computed off the main thread by `SystemStatsViewModel` and
/// published to SwiftUI via `@Published` on the main thread.
struct SystemStats {
    /// CPU utilisation across all cores, 0–100 %.
    var cpuPct: Double
    /// Memory actively in use (active + wired pages × page size), in GB.
    var memUsedGB: Double
    /// Physical RAM installed, in GB.
    var memTotalGB: Double
    /// Disk space occupied (total − free), in GB.
    var diskUsedGB: Double
    /// Raw partition capacity from `volumeTotalCapacity`, in GB.
    var diskTotalGB: Double
    /// Available disk space from `volumeAvailableCapacityKey`, in GB.
    var diskFreeGB: Double
    /// Free disk space as a percentage of total: (diskFreeGB / diskTotalGB) × 100.
    var diskFreePct: Double

    /// Safe default shown while the first sample is being computed.
    static let zero = SystemStats(
        cpuPct: 0, memUsedGB: 0, memTotalGB: 16,
        diskUsedGB: 0, diskTotalGB: 460, diskFreeGB: 460, diskFreePct: 100
    )
}

/// CPU tick counters captured from `host_processor_info()`.
private struct CPUTicks {
    var user: Double
    var system: Double
    var total: Double
}

/// Memory usage snapshot in GB.
private struct MemoryStats {
    var used: Double
    var total: Double
}

/// Disk usage snapshot in GB and percent free.
private struct DiskStats {
    var used: Double
    var total: Double
    var free: Double
    var freePct: Double
}

// MARK: - SystemStatsViewModel

/// ObservableObject that owns the 2-second polling loop for system metrics.
///
/// Threading model: all samples are dispatched on a private serial queue
/// (`samplingQueue`) to prevent `prevTicks` races, then published to SwiftUI
/// on the main thread via `DispatchQueue.main.async`.
///
/// Lifecycle: `init()` is intentionally a no-op. The owner (PopoverMainView)
/// calls `start()` in `.onAppear` and `stop()` in `.onDisappear` so the timer
/// only runs while the popover is visible.
final class SystemStatsViewModel: ObservableObject {
    @Published var stats: SystemStats = .zero

    private var timer: Timer?
    private var prevTicks = CPUTicks(user: 0, system: 0, total: 0)

    private let samplingQueue = DispatchQueue(
        label: "RunnerBar.SystemStatsViewModel.sampling",
        qos: .utility
    )

    init() {}
    deinit { timer?.invalidate() }

    func start() {
        timer?.invalidate()
        samplingQueue.async { [weak self] in self?.sample() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.samplingQueue.async { [weak self] in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - CPU

    private func cpuPercent() -> Double {
        var cpuInfo: processor_info_array_t?
        var msgType = natural_t(0)
        var numCPUInfo = mach_msg_type_number_t(0)
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &msgType, &cpuInfo, &numCPUInfo
        ) == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        let numCPUs = Int(msgType)
        var userTicks = 0.0
        var sysTicks = 0.0
        var totalTicks = 0.0
        for coreIdx in 0 ..< numCPUs {
            let base = Int32(CPU_STATE_MAX) * Int32(coreIdx)
            let userLoad = Double(info[Int(base) + Int(CPU_STATE_USER)])
            let sysLoad = Double(info[Int(base) + Int(CPU_STATE_SYSTEM)])
            let idleLoad = Double(info[Int(base) + Int(CPU_STATE_IDLE)])
            let niceLoad = Double(info[Int(base) + Int(CPU_STATE_NICE)])
            userTicks += userLoad + niceLoad
            sysTicks += sysLoad
            totalTicks += userLoad + sysLoad + idleLoad + niceLoad
        }
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: cpuInfo),
            vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        )
        let currentTicks = CPUTicks(user: userTicks, system: sysTicks, total: totalTicks)
        let dUser = currentTicks.user - prevTicks.user
        let dSys = currentTicks.system - prevTicks.system
        let dTotal = currentTicks.total - prevTicks.total
        prevTicks = currentTicks
        guard dTotal > 0 else { return 0 }
        return min(100, ((dUser + dSys) / dTotal) * 100)
    }

    // MARK: - Memory

    private func memStats() -> MemoryStats {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let kernResult = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kernResult == KERN_SUCCESS else { return MemoryStats(used: 0, total: 16) }
        let pageSize = Double(vm_kernel_page_size)
        let gigabytes = 1024.0 * 1024.0 * 1024.0
        let used = Double(vmStats.active_count + vmStats.wire_count) * pageSize / gigabytes
        var memSize: UInt64 = 0
        var memSizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0)
        let total = Double(memSize) / gigabytes
        return MemoryStats(used: used, total: total)
    }

    // MARK: - Disk

    /// Uses `volumeAvailableCapacityKey` (NOT `volumeAvailableCapacityForImportantUsageKey`).
    /// ⚠️ PERMISSION GUARD: `volumeAvailableCapacityForImportantUsageKey` triggers macOS TCC
    /// dialogs ("access data from other apps", Apple Music) on every popover open.
    /// `volumeAvailableCapacityKey` is TCC-free and returns a slightly more conservative
    /// free-space estimate, which is fine for display purposes.
    /// ❌ NEVER switch back to volumeAvailableCapacityForImportantUsageKey.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private func diskStats() -> DiskStats {
        let url = URL(fileURLWithPath: "/")
        let gigabytes = 1024.0 * 1024.0 * 1024.0
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]),
        let totalBytes = values.volumeTotalCapacity,
        let freeBytes = values.volumeAvailableCapacity
        else { return DiskStats(used: 0, total: 460, free: 460, freePct: 100) }
        let total = Double(totalBytes) / gigabytes
        let free = Double(freeBytes) / gigabytes
        let used = total - free
        let freePct = total > 0 ? (free / total) * 100 : 100
        return DiskStats(used: used, total: total, free: free, freePct: freePct)
    }

    // MARK: - Sample

    private func sample() {
        let cpu = cpuPercent()
        let mem = memStats()
        let disk = diskStats()
        let snapshot = SystemStats(
            cpuPct: cpu,
            memUsedGB: mem.used, memTotalGB: mem.total,
            diskUsedGB: disk.used, diskTotalGB: disk.total,
            diskFreeGB: disk.free, diskFreePct: disk.freePct
        )
        DispatchQueue.main.async { self.stats = snapshot }
    }
}
