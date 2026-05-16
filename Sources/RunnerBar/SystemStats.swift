import Combine
import Darwin
import Foundation

// MARK: - SystemStatsSnapshot

/// Immutable snapshot of CPU and memory utilisation at a point in time.
struct SystemStatsSnapshot {
    /// CPU utilisation as a percentage (0–100).
    let cpuPercent: Double
    /// Memory utilisation as a percentage (0–100).
    let memPercent: Double
}

// MARK: - SystemStats

/// Snapshot of system resource utilisation used by the popover header.
struct SystemStats {
    /// CPU utilisation percentage (0–100).
    var cpuPct: Double = 0
    /// Memory currently in use, in GB.
    var memUsedGB: Double = 0
    /// Total physical memory, in GB.
    var memTotalGB: Double = 0
    /// Disk space currently used on the boot volume, in GB.
    var diskUsedGB: Double = 0
    /// Total disk capacity of the boot volume, in GB.
    var diskTotalGB: Double = 0
    /// A zero-value snapshot.
    static let zero = SystemStats()
}

// MARK: - SystemStatsViewModel

/// ObservableObject that drives the system-stats header in `PopoverMainView`.
/// Publishes `stats`, `cpuHistory`, `memHistory`, and `diskHistory` on the main thread.
///
/// ⚠️ SINGLETON — use `.shared`. Must NOT be created as @StateObject in views;
/// history must survive popover close/reopen so sparklines show immediately on open.
final class SystemStatsViewModel: ObservableObject {
    /// Shared singleton — history accumulates for the lifetime of the app.
    static let shared = SystemStatsViewModel()

    /// Current system resource snapshot.
    @Published var stats = SystemStats.zero
    /// Rolling CPU usage history (0.0–1.0 values for SparklineView).
    @Published var cpuHistory: [Double] = []
    /// Rolling memory usage history (0.0–1.0 values for SparklineView).
    @Published var memHistory: [Double] = []
    /// Rolling disk usage history (0.0–1.0 values for SparklineView).
    @Published var diskHistory: [Double] = []

    private let maxHistory = 60
    // ⚠️ 2s interval — sparkline needs ≥2 points; 5s meant blank graph for first 10s
    private let pollInterval: TimeInterval = 2
    private var timer: Timer?
    // For non-blocking delta CPU (host_processor_info)
    private var prevCPUInfo: processor_info_array_t?
    private var prevCPUInfoCount: mach_msg_type_number_t = 0

    private init() {}

    // MARK: - Lifecycle

    /// Starts a repeating poll. Safe to call multiple times — no-ops if already running.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll() // immediate first sample — no waiting for first tick
    }

    /// Stops the repeating poll timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private

    private func poll() {
        // Disk reads are cheap; cpu/mem are fast with host APIs — no need for background thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = self.collectStats()
            DispatchQueue.main.async {
                self.stats = snapshot
                self.append(snapshot.cpuPct, to: &self.cpuHistory)
                self.append(snapshot.memTotalGB > 0
                    ? (snapshot.memUsedGB / snapshot.memTotalGB) * 100
                    : 0, to: &self.memHistory)
                self.append(snapshot.diskTotalGB > 0
                    ? (snapshot.diskUsedGB / snapshot.diskTotalGB) * 100
                    : 0, to: &self.diskHistory)
            }
        }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value / 100.0)
        if history.count > maxHistory { history.removeFirst() }
    }

    // MARK: - System calls

    private func collectStats() -> SystemStats {
        var snapshot = SystemStats()
        snapshot.cpuPct      = cpuUsage()
        snapshot.memUsedGB   = memUsedGB()
        snapshot.memTotalGB  = memTotalGB()
        snapshot.diskUsedGB  = diskUsedGB()
        snapshot.diskTotalGB = diskTotalGB()
        return snapshot
    }

    /// Non-blocking CPU usage via host_processor_info delta — no `top` subprocess.
    ///
    /// Memory ownership:
    /// - `host_processor_info` allocates a Mach VM buffer that the caller must free.
    /// - We keep the *current* buffer alive as `prevCPUInfo` so the next call can
    ///   compute a delta. The old `prevCPUInfo` is freed each time it is replaced.
    /// - ⚠️ Do NOT add a `defer` block that frees `info` — that would free the pointer
    ///   immediately after storing it in `prevCPUInfo`, causing a use-after-free crash
    ///   (SIGSEGV / KERN_INVALID_ADDRESS) on the second call.
    private func cpuUsage() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs,
                                         &cpuInfo,
                                         &numCPUInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return 0 }

        var totalUser: Double = 0, totalSys: Double = 0
        var totalIdle: Double = 0, totalNice: Double = 0

        for coreIdx in 0 ..< Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * coreIdx
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let sys  = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])

            if let prev = prevCPUInfo {
                let deltaUser = user - Double(prev[base + Int(CPU_STATE_USER)])
                let deltaSys  = sys  - Double(prev[base + Int(CPU_STATE_SYSTEM)])
                let deltaIdle = idle - Double(prev[base + Int(CPU_STATE_IDLE)])
                let deltaNice = nice - Double(prev[base + Int(CPU_STATE_NICE)])
                let total = deltaUser + deltaSys + deltaIdle + deltaNice
                if total > 0 {
                    totalUser += deltaUser
                    totalSys  += deltaSys
                    totalIdle += deltaIdle
                    totalNice += deltaNice
                }
            } else {
                totalUser += user; totalSys += sys
                totalIdle += idle; totalNice += nice
            }
        }

        // Free the old buffer now that we've finished reading it, then store the new one.
        if let prev = prevCPUInfo {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: prev),
                          vm_size_t(Int(prevCPUInfoCount) * MemoryLayout<integer_t>.size))
        }
        prevCPUInfo = info
        prevCPUInfoCount = numCPUInfo

        let total = totalUser + totalSys + totalIdle + totalNice
        guard total > 0 else { return 0 }
        return min(((totalUser + totalSys + totalNice) / total) * 100.0, 100.0)
    }

    private func memTotalGB() -> Double {
        let output = shell("sysctl -n hw.memsize", timeout: 3)
        guard let bytes = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return bytes / 1_073_741_824
    }

    private func memUsedGB() -> Double {
        let output = shell("vm_stat", timeout: 3)
        var active: Double = 0, wired: Double = 0, compressed: Double = 0
        for line in output.components(separatedBy: "\n") {
            let lineNums = line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            let val = Double(lineNums) ?? 0
            if line.contains("Pages active")   { active     = val }
            if line.contains("Pages wired")    { wired      = val }
            if line.contains("Pages occupied") { compressed = val }
        }
        return ((active + wired + compressed) * 16384) / 1_073_741_824
    }

    private func diskTotalGB() -> Double {
        let output = shell("df -k / | tail -1", timeout: 3)
        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2, let kilobytes = Double(parts[1]) else { return 0 }
        return kilobytes / 1_048_576
    }

    private func diskUsedGB() -> Double {
        let output = shell("df -k / | tail -1", timeout: 3)
        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 3, let kilobytes = Double(parts[2]) else { return 0 }
        return kilobytes / 1_048_576
    }
}

// MARK: - SystemStatsPoller

/// Legacy poller kept for observer-pattern consumers. Prefer `SystemStatsViewModel`.
final class SystemStatsPoller {
    /// Shared singleton instance.
    static let shared = SystemStatsPoller()
    /// Most recent snapshot produced by the background poll.
    private(set) var latest = SystemStatsSnapshot(cpuPercent: 0, memPercent: 0)
    private var observers: [(SystemStatsSnapshot) -> Void] = []
    private let lock = NSLock()
    private init() {}

    /// Starts the background polling loop at `interval` seconds.
    func start(interval: TimeInterval = 5) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while true {
                let snapshot = self.poll()
                self.lock.lock()
                self.latest = snapshot
                let obs = self.observers
                self.lock.unlock()
                DispatchQueue.main.async { obs.forEach { $0(snapshot) } }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    /// Registers an observer block and returns a token.
    @discardableResult
    func addObserver(_ block: @escaping (SystemStatsSnapshot) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        observers.append(block)
        return observers.count - 1
    }

    private func poll() -> SystemStatsSnapshot {
        SystemStatsSnapshot(cpuPercent: cpuUsage(), memPercent: memUsage())
    }

    private func cpuUsage() -> Double {
        let output = shell("top -l 1 -n 0 | grep 'CPU usage'", timeout: 5)
        var used = 0.0
        for part in output.components(separatedBy: ",") {
            if part.contains("idle") { continue }
            let nums = part.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let val = Double(nums) { used += val }
        }
        return min(used, 100)
    }

    private func memUsage() -> Double {
        let output = shell("memory_pressure | grep 'System memory pressure'", timeout: 5)
        let nums = output.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Double(nums) ?? 0
    }
}
