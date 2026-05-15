import Foundation

// MARK: - SystemStatsSnapshot

/// Immutable snapshot of CPU and memory utilisation at a point in time.
struct SystemStatsSnapshot {
    /// CPU utilisation as a percentage (0–100).
    let cpuPercent: Double
    /// Memory utilisation as a percentage (0–100).
    let memPercent: Double
}

// MARK: - SystemStatsPoller

/// Polls CPU and memory usage on a background thread and publishes snapshots.
final class SystemStatsPoller {
    /// Shared singleton.
    static let shared = SystemStatsPoller()

    /// Latest snapshot; always non-nil after the first poll.
    private(set) var latest: SystemStatsSnapshot = SystemStatsSnapshot(cpuPercent: 0, memPercent: 0)

    /// Registered observers called on the main thread after each poll.
    private var observers: [(SystemStatsSnapshot) -> Void] = []
    private let lock = NSLock()

    private init() {}

    /// Starts polling at the given interval (default 5 s).
    func start(interval: TimeInterval = 5) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while true {
                let snapshot = self.poll()
                self.lock.lock()
                self.latest = snapshot
                let obs = self.observers
                self.lock.unlock()
                DispatchQueue.main.async {
                    obs.forEach { $0(snapshot) }
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    /// Adds an observer closure; returns a token that can be used to remove it.
    @discardableResult
    func addObserver(_ block: @escaping (SystemStatsSnapshot) -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        observers.append(block)
        return observers.count - 1
    }

    // MARK: - Private

    private func poll() -> SystemStatsSnapshot {
        let cpu = cpuUsage()
        let mem = memUsage()
        return SystemStatsSnapshot(cpuPercent: cpu, memPercent: mem)
    }

    /// Returns overall CPU utilisation via `top -l 1`.
    private func cpuUsage() -> Double {
        let output = shell("top -l 1 -n 0 | grep 'CPU usage'", timeout: 5)
        // e.g. "CPU usage: 4.54% user, 8.18% sys, 87.27% idle"
        let parts = output.components(separatedBy: ",")
        var used = 0.0
        for part in parts {
            if part.contains("idle") { continue }
            let nums = part.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .joined()
            if let val = Double(nums) {
                used += val
            }
        }
        return min(used, 100)
    }

    /// Returns memory pressure percentage via `memory_pressure`.
    private func memUsage() -> Double {
        let output = shell("memory_pressure | grep 'System memory pressure'", timeout: 5)
        // e.g. "System memory pressure: 23%"
        let nums = output.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Double(nums) ?? 0
    }
}
