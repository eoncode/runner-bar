// SystemStatsViewModel.swift
// RunnerBar
import Combine
@preconcurrency import Darwin
import Foundation
import RunnerBarCore

// MARK: - RingBuffer
/// Fixed-capacity circular buffer whose `values` property returns elements oldest-first.
struct RingBuffer {
    /// The storage property.
    private var storage: [Double]

    /// Creates a new instance.
    init(capacity: Int, fill: Double = 0) {
        self.storage = Array(repeating: fill, count: capacity)
    }

    /// Drops the oldest element and appends `value` at the tail.
    /// - Parameter value: The new sample to insert.
    mutating func append(_ value: Double) {
        storage.removeFirst()
        storage.append(value)
    }

    /// Elements in insertion order (oldest first).
    var values: [Double] { storage }
}

// MARK: - SystemStatsViewModel
/// Observable view-model that periodically samples CPU, memory, and disk metrics.
/// Call `start()` when the owning view appears and `stop()` when it disappears.
@MainActor
final class SystemStatsViewModel: ObservableObject {
    /// Latest sampled snapshot, ready for display.
    @Published private(set) var stats: SystemStats = .zero
    /// Rolling 60-sample history for CPU sparkline charts.
    @Published private(set) var cpuHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Rolling 60-sample history for memory-usage sparkline charts.
    @Published private(set) var memHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Rolling 60-sample history for disk-usage sparkline charts.
    @Published private(set) var diskHistory: RingBuffer = RingBuffer(capacity: 60)

    /// The timer property.
    /// Safety: only mutated on MainActor (start/stop). Captured as a local `let` in
    /// deinit before dispatching invalidation to the main run loop — Timer.invalidate()
    /// must be called on the thread that installed the timer (main run loop).
    nonisolated(unsafe) private var timer: Timer?
    /// The prevCPUInfo property.
    /// Safety: accessed only from `sampleCPU()` (always called on MainActor) and
    /// `deinit` (which implies no other references exist, so no concurrent access is possible).
    nonisolated(unsafe) private var prevCPUInfo: processor_info_array_t?
    /// The prevNumCPUInfo property.
    /// Safety: same as `prevCPUInfo` — MainActor during sampling, no concurrency in deinit.
    nonisolated(unsafe) private var prevNumCPUInfo: mach_msg_type_number_t = 0
    /// Root volume path used for disk-space queries.
    private static let rootVolumePath = NSOpenStepRootDirectory()

    /// Creates a new instance.
    init() {
        // No custom initialisation needed; all properties have defaults.
    }

    deinit {
        // Timer.invalidate() must be called on the thread that installed the timer (main run loop).
        // deinit is nonisolated in Swift 6 and may run off-main, so we dispatch explicitly.
        let t = timer
        DispatchQueue.main.async { t?.invalidate() }
        deallocPrevCPUInfo()
    }

    // MARK: Lifecycle
    /// Starts the 2-second repeating timer and takes an immediate first sample.
    /// Safe to call multiple times — no-ops if the timer is already running.
    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    /// Invalidates the sampling timer. Call from `onDisappear`.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Sampling
    /// Collects CPU, memory, and disk snapshots and publishes the new ``stats``
    /// and updated history ring-buffers. Runs on the MainActor.
    private func sample() {
        let cpu = sampleCPU()
        let mem = sampleMemory()
        let disk = sampleDisk()
        let snapshot = SystemStats(
            cpuPct: cpu,
            memUsedGB: mem.used,
            memTotalGB: mem.total,
            diskUsedGB: disk.used,
            diskTotalGB: disk.total
        )
        var newCPU = cpuHistory
        var newMem = memHistory
        var newDisk = diskHistory
        newCPU.append(cpu)
        let memPct = mem.total > 0 ? mem.used / mem.total * 100 : 0.0
        let diskPct = disk.total > 0 ? disk.used / disk.total * 100 : 0.0
        newMem.append(memPct)
        newDisk.append(diskPct)
        self.stats = snapshot
        self.cpuHistory = newCPU
        self.memHistory = newMem
        self.diskHistory = newDisk
    }

    // MARK: CPU (Mach host_processor_info)
    // swiftlint:disable:next function_body_length
    /// Reads per-core tick counts via `host_processor_info` and returns the
    /// aggregate CPU utilisation as a percentage (0–100).
    /// Diffs against the previous sample stored in `prevCPUInfo`; returns `0` on the first call.
    /// - Returns: CPU usage percentage, or `0` if the kernel call fails.
    private func sampleCPU() -> Double {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUsU,
            &cpuInfo,
            &numCPUInfo
        )
        guard kr == KERN_SUCCESS, let cpuInfo else { return 0 }
        defer {
            deallocPrevCPUInfo()
            prevCPUInfo = cpuInfo
            prevNumCPUInfo = numCPUInfo
        }
        guard let prevInfo = prevCPUInfo else { return 0 }
        var totalUsed: Double = 0
        var totalAll: Double = 0
        let numCPUs = Int(numCPUsU)
        for i in 0 ..< numCPUs {
            let base = Int(CPU_STATE_MAX) * i
            let userDelta   = Double(cpuInfo[base + Int(CPU_STATE_USER)]   - prevInfo[base + Int(CPU_STATE_USER)])
            let sysDelta    = Double(cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevInfo[base + Int(CPU_STATE_SYSTEM)])
            let idleDelta   = Double(cpuInfo[base + Int(CPU_STATE_IDLE)]   - prevInfo[base + Int(CPU_STATE_IDLE)])
            let niceDelta   = Double(cpuInfo[base + Int(CPU_STATE_NICE)]   - prevInfo[base + Int(CPU_STATE_NICE)])
            let used = userDelta + sysDelta + niceDelta
            totalUsed += used
            totalAll  += used + idleDelta
        }
        guard totalAll > 0 else { return 0 }
        return totalUsed / totalAll * 100
    }

    /// Deallocates the Mach `processor_info_array_t` buffer stored in `prevCPUInfo`
    /// using `vm_deallocate`, then nils the pointer. Safe to call when `prevCPUInfo` is `nil`.
    /// `nonisolated` so it can be called from `deinit` (which is always nonisolated) and from
    /// `sampleCPU()`'s `defer` block without crossing an actor boundary.
    nonisolated private func deallocPrevCPUInfo() {
        guard let prev = prevCPUInfo else { return }
        let infoSize  = vm_size_t(MemoryLayout<integer_t>.size)
        let totalSize = vm_size_t(prevNumCPUInfo) * infoSize
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), totalSize)
        prevCPUInfo = nil
    }

    // MARK: Memory (vm_statistics64)
    /// Queries `host_statistics64` for `HOST_VM_INFO64` and converts page counts to gigabytes.
    /// - Returns: `(used, total)` in GB; `used` counts active + wired + compressor pages.
    private func sampleMemory() -> (used: Double, total: Double) {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = Double(Int(vm_kernel_page_size))
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB    = totalBytes / 1_000_000_000
        guard kr == KERN_SUCCESS else { return (0, totalGB) }
        let usedPages = Double(
            vmStats.active_count +
            vmStats.wire_count +
            vmStats.compressor_page_count
        )
        let usedGB = usedPages * pageSize / 1_000_000_000
        return (usedGB, totalGB)
    }

    // MARK: Disk (FileManager)
    /// Reads total and free bytes for the root volume via `FileManager` and returns used/total in GB.
    /// - Returns: `(used, total)` in GB, or `(0, 0)` if the file-system query fails.
    private func sampleDisk() -> (used: Double, total: Double) {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: Self.rootVolumePath),
            let total = attrs[.systemSize] as? Int64,
            let free  = attrs[.systemFreeSize] as? Int64
        else { return (0, 0) }
        let totalGB = Double(total) / 1_000_000_000
        let usedGB  = Double(total - free) / 1_000_000_000
        return (usedGB, totalGB)
    }
}
