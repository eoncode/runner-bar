import Combine
import Foundation

// MARK: - SystemStatsPoller (legacy)

/// Continuously polls CPU and memory usage on a background thread.
final class SystemStatsPoller2 {
    /// Shared singleton instance.
    static let shared = SystemStatsPoller2()
    private init() {}

    private var observers: [Int: (SystemStatsSnapshot) -> Void] = [:]
    private var nextID = 0
    private let lock = NSLock()
    private var isStarted = false

    /// Registers an observer block and returns a stable token for later removal.
    func addObserver(_ block: @escaping (SystemStatsSnapshot) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let observerID = nextID; nextID += 1
        observers[observerID] = block
        return observerID
    }

    /// Removes the observer identified by `token`.
    func removeObserver(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: token)
    }

    /// Starts the background polling thread if not already running.
    func start() {
        lock.lock()
        if isStarted { lock.unlock(); return }
        isStarted = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while true {
                let snapshot = Self.poll()
                self.lock.lock()
                let blocks = Array(self.observers.values)
                self.lock.unlock()
                for block in blocks { block(snapshot) }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private static func poll() -> SystemStatsSnapshot {
        let cpu = fetchCPU()
        let mem = fetchMem()
        return SystemStatsSnapshot(cpuPercent: cpu, memPercent: mem)
    }

    private static func fetchCPU() -> Double {
        let output = shell("top -l 1 -s 0 | grep 'CPU usage'", timeout: 5)
        guard let range = output.range(of: #"(\d+\.\d+)% user"#, options: .regularExpression) else { return 0 }
        return Double(output[range].components(separatedBy: "%").first ?? "") ?? 0
    }

    private static func fetchMem() -> Double {
        let output = shell("vm_stat", timeout: 5)
        var pagesFree = 0.0
        var pagesActive = 0.0
        var pagesInactive = 0.0
        var pagesWired = 0.0
        for line in output.components(separatedBy: "\n") {
            func extract(_ key: String) -> Double? {
                guard line.contains(key),
                      let val = line.components(separatedBy: ":").last?
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ".", with: "")
                else { return nil }
                return Double(val)
            }
            if let val = extract("Pages free")       { pagesFree    = val }
            if let val = extract("Pages active")     { pagesActive  = val }
            if let val = extract("Pages inactive")   { pagesInactive = val }
            if let val = extract("Pages wired down") { pagesWired   = val }
        }
        let total = pagesFree + pagesActive + pagesInactive + pagesWired
        guard total > 0 else { return 0 }
        return ((pagesActive + pagesWired) / total) * 100
    }
}
