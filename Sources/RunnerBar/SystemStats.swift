import Combine
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
    /// Constructs a zero-value snapshot.
    static let zero = SystemStats()
}

// MARK: - SystemStatsViewModel

/// ObservableObject that drives the system-stats header in `PopoverMainView`.
/// Publishes `stats`, `cpuHistory`, `memHistory`, and `diskHistory` on the main thread.
final class SystemStatsViewModel: ObservableObject {
    /// Current system resource snapshot.
    @Published var stats = SystemStats.zero
    /// Rolling CPU usage history (0.0–1.0 values for SparklineView).
    @Published var cpuHistory: [Double] = []
    /// Rolling memory usage history (0.0–1.0 values for SparklineView).
    @Published var memHistory: [Double] = []
    /// Rolling disk usage history (0.0–1.0 values for SparklineView).
    @Published var diskHistory: [Double] = []

    private let maxHistory = 30
    private var timer: Timer?

    // MARK: - Lifecycle

    /// Starts a repeating 5-second poll.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    /// Stops the repeating poll timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private

    private func poll() {
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
        history.append(value / 100.0)   // SparklineView expects 0.0–1.0
        if history.count > maxHistory { history.removeFirst() }
    }

    // MARK: - System calls

    private func collectStats() -> SystemStats {
        var snapshot = SystemStats()
        snapshot.cpuPct     = cpuUsage()
        snapshot.memUsedGB  = memUsedGB()
        snapshot.memTotalGB = memTotalGB()
        snapshot.diskUsedGB = diskUsedGB()
        snapshot.diskTotalGB = diskTotalGB()
        return snapshot
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

    private func memTotalGB() -> Double {
        let output = shell("sysctl -n hw.memsize", timeout: 5)
        guard let bytes = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return bytes / 1_073_741_824
    }

    private func memUsedGB() -> Double {
        // vm_stat gives pages; page size is typically 16384 bytes on Apple Silicon.
        let output = shell("vm_stat", timeout: 5)
        var active: Double = 0, wired: Double = 0, compressed: Double = 0
        for line in output.components(separatedBy: "\n") {
            let lineNums = line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            let val = Double(lineNums) ?? 0
            if line.contains("Pages active")     { active     = val }
            if line.contains("Pages wired")      { wired      = val }
            if line.contains("Pages occupied")   { compressed = val }
        }
        let pages = active + wired + compressed
        return (pages * 16384) / 1_073_741_824
    }

    private func diskTotalGB() -> Double {
        let output = shell("df -k / | tail -1", timeout: 5)
        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2, let kilobytes = Double(parts[1]) else { return 0 }
        return kilobytes / 1_048_576
    }

    private func diskUsedGB() -> Double {
        let output = shell("df -k / | tail -1", timeout: 5)
        let parts = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 3, let kilobytes = Double(parts[2]) else { return 0 }
        return kilobytes / 1_048_576
    }
}

// MARK: - SystemStatsPoller (legacy — kept for any remaining observers)

/// Polls CPU and memory usage on a background thread and publishes snapshots.
final class SystemStatsPoller {
    /// Shared singleton instance.
    static let shared = SystemStatsPoller()
    /// Most recent snapshot produced by the background poll.
    private(set) var latest: SystemStatsSnapshot = SystemStatsSnapshot(cpuPercent: 0, memPercent: 0)
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

    /// Registers an observer block and returns a token (unused; kept for API compatibility).
    @discardableResult
    func addObserver(_ block: @escaping (SystemStatsSnapshot) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        observers.append(block)
        return observers.count - 1
    }

    private func poll() -> SystemStatsSnapshot {
        let cpu = cpuUsage()
        let mem = memUsage()
        return SystemStatsSnapshot(cpuPercent: cpu, memPercent: mem)
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
