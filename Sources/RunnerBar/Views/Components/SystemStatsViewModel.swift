// SystemStatsViewModel.swift
// RunnerBar
@preconcurrency import Darwin
import Foundation
import Observation
import RunnerBarCore

// MARK: - SystemStatsViewModel
/// Observable view-model that periodically samples CPU, memory, and disk metrics.
/// Call `start()` when the owning view appears and `stop()` when it disappears.
@MainActor
@Observable
final class SystemStatsViewModel {
    /// Latest sampled snapshot, ready for display.
    private(set) var stats: SystemStats = .zero
    /// Rolling 60-sample history for CPU sparkline charts.
    private(set) var cpuHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Rolling 60-sample history for memory-usage sparkline charts.
    private(set) var memHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Rolling 60-sample history for disk-usage sparkline charts.
    private(set) var diskHistory: RingBuffer = RingBuffer(capacity: 60)
    /// Structured task driving the 2-second sample loop.
    /// Cancelled in `stop()` and `deinit`; `@ObservationIgnored` keeps it out of
    /// the `@Observable` macro's tracking storage.
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    /// Per-core CPU tick counts from the previous `host_processor_info` call.
    /// Accessed exclusively on `@MainActor` — no concurrent access is possible,
    /// so `nonisolated(unsafe)` is no longer needed.
    @ObservationIgnored private var prevCPUInfo: processor_info_array_t?
    /// Entry count of `prevCPUInfo`, required by `vm_deallocate` for correct deallocation size.
    @ObservationIgnored private var prevNumCPUInfo: mach_msg_type_number_t = 0
    /// Root volume path used for disk-space queries via `FileManager.attributesOfFileSystem`.
    private static let rootVolumePath = NSOpenStepRootDirectory()

    /// Creates a new instance; all properties are default-initialised.
    init() { /* no custom setup required — all stored properties have default values */ }

    deinit {
        // Task.cancel() is safe to call from any isolation context — no DispatchQueue hop needed.
        samplingTask?.cancel()
        deallocPrevCPUInfo()
    }

    // MARK: Lifecycle

    /// Starts the 2-second structured sample loop and takes an immediate first sample.
    /// Safe to call multiple times — no-ops if the loop is already running.
    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            // Immediate first sample before the first sleep.
            self?.sample()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    break   // clean cooperative cancellation — exit silently
                } catch {
                    break   // unexpected error — exit defensively
                }
                guard !Task.isCancelled else { break }
                self?.sample()
            }
        }
    }

    /// Cancels the sampling loop immediately. Call from `onDisappear`.
    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    // MARK: Sampling
    /// Collects CPU, memory, and disk snapshots and publishes updated stats and history buffers.
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

    // MARK: CPU
    // Mach host_processor_info diff loop — cannot be extracted without losing clarity.
    /// Reads per-core tick counts via `host_processor_info` and returns aggregate CPU usage (0-100).
    /// Diffs against the previous sample; returns `0` on the first call or if the kernel call fails.
    private func sampleCPU() -> Double {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCPUInfo)
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
            let userDelta = Double(cpuInfo[base + Int(CPU_STATE_USER)] - prevInfo[base + Int(CPU_STATE_USER)])
            let sysDelta = Double(cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevInfo[base + Int(CPU_STATE_SYSTEM)])
            let idleDelta = Double(cpuInfo[base + Int(CPU_STATE_IDLE)] - prevInfo[base + Int(CPU_STATE_IDLE)])
            let niceDelta = Double(cpuInfo[base + Int(CPU_STATE_NICE)] - prevInfo[base + Int(CPU_STATE_NICE)])
            let used = userDelta + sysDelta + niceDelta
            totalUsed += used
            totalAll += used + idleDelta
        }
        guard totalAll > 0 else { return 0 }
        return totalUsed / totalAll * 100
    }

    /// Deallocates the `prevCPUInfo` Mach buffer via `vm_deallocate` and nils the pointer.
    /// Called from `sampleCPU()`'s `defer` block (always on `@MainActor`) and from `deinit`.
    private func deallocPrevCPUInfo() {
        guard let prev = prevCPUInfo else { return }
        let infoSize = vm_size_t(MemoryLayout<integer_t>.size)
        let totalSize = vm_size_t(prevNumCPUInfo) * infoSize
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), totalSize)
        prevCPUInfo = nil
    }

    // MARK: Memory
    /// Queries `host_statistics64` for `HOST_VM_INFO64` and converts page counts to gigabytes.
    /// - Returns: `(used, total)` in GB where `used` counts active + wired + compressor pages.
    private func sampleMemory() -> (used: Double, total: Double) {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = Double(Int(vm_kernel_page_size))
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / 1_000_000_000
        guard kr == KERN_SUCCESS else { return (0, totalGB) }
        let usedPages = Double(vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count)
        let usedGB = usedPages * pageSize / 1_000_000_000
        return (usedGB, totalGB)
    }

    // MARK: Disk
    /// Reads total and free bytes for the root volume and returns used/total in GB.
    /// - Returns: `(used, total)` in GB, or `(0, 0)` if the file-system query fails.
    /// - Note: Casts to `Int64`; safe for volumes up to ~9.2 EB. If Apple Silicon Macs ever
    ///   ship volumes exceeding `Int64.max`, migrate to `UInt64` casts here.
    private func sampleDisk() -> (used: Double, total: Double) {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: Self.rootVolumePath),
            let total = attrs[.systemSize] as? Int64,
            let free = attrs[.systemFreeSize] as? Int64
        else { return (0, 0) }
        let totalGB = Double(total) / 1_000_000_000
        let usedGB = Double(total - free) / 1_000_000_000
        return (usedGB, totalGB)
    }
}
