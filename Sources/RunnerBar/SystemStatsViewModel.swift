import Combine
import Darwin
import Foundation

// MARK: - RingBuffer
/// Fixed-capacity circular buffer whose `values` property returns elements oldest-first.
struct RingBuffer {
    private var storage: [Double]
    private let capacity: Int

    init(capacity: Int, fill: Double = 0) {
        self.capacity = capacity
        self.storage = Array(repeating: fill, count: capacity)
    }

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
final class SystemStatsViewModel: ObservableObject {
    /// Latest sampled snapshot, ready for display.
    @Published private(set) var stats: SystemStats = .zero

    /// Rolling 60-sample history for sparkline charts.
    @Published private(set) var cpuHistory: RingBuffer = RingBuffer(capacity: 60)
    @Published private(set) var memHistory: RingBuffer = RingBuffer(capacity: 60)
    @Published private(set) var diskHistory: RingBuffer = RingBuffer(capacity: 60)

    private var timer: Timer?
    private var prevCPUInfo: processor_info_array_t?
    private var prevNumCPUInfo: mach_msg_type_number_t = 0

    /// Root volume path used for disk-space queries.
    private static let rootVolumePath = "/"

    init() {
        // No custom initialisation needed; all properties have defaults.
    }

    deinit {
        stop()
        deallocPrevCPUInfo()
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Sampling

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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stats = snapshot
            self.cpuHistory = newCPU
            self.memHistory = newMem
            self.diskHistory = newDisk
        }
    }

    // MARK: CPU (Mach host_processor_info)

    // swiftlint:disable:next function_body_length
    private func sampleCPU() -> Double {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUsU, &cpuInfo, &numCPUInfo)
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

    private func deallocPrevCPUInfo() {
        guard let prev = prevCPUInfo else { return }
        let infoSize = vm_size_t(MemoryLayout<integer_t>.size)
        let totalSize = vm_size_t(prevNumCPUInfo) * infoSize
        vm_deallocate(mach_task_self_,
                      vm_address_t(bitPattern: prev),
                      totalSize)
        prevCPUInfo = nil
    }

    // MARK: Memory (vm_statistics64)

    private func sampleMemory() -> (used: Double, total: Double) {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = Double(vm_kernel_page_size)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / 1_000_000_000
        guard kr == KERN_SUCCESS else { return (0, totalGB) }
        let usedPages = Double(vmStats.active_count + vmStats.wire_count +
                                vmStats.compressor_page_count)
        let usedGB = usedPages * pageSize / 1_000_000_000
        return (usedGB, totalGB)
    }

    // MARK: Disk (FileManager)

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
