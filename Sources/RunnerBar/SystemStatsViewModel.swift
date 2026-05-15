// swiftlint:disable missing_docs
import Foundation
import Combine

// MARK: - SystemStatsSnapshot

/// Lightweight value type carrying a CPU and memory usage snapshot.
struct SystemStatsSnapshot {
    /// CPU usage as a percentage (0–100).
    let cpuPercent: Double
    /// Memory usage as a percentage (0–100).
    let memPercent: Double
}

// MARK: - SystemStatsPoller

/// Continuously polls CPU and memory usage on a background thread.
final class SystemStatsPoller {
    static let shared = SystemStatsPoller()
    private init() {}

    private var observers: [Int: (SystemStatsSnapshot) -> Void] = [:]
    private var nextID = 0
    private let lock = NSLock()
    private var isStarted = false

    func addObserver(_ block: @escaping (SystemStatsSnapshot) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID; nextID += 1
        observers[id] = block
        return id
    }

    func removeObserver(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: token)
    }

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
        if let range = output.range(of: #"(\d+\.\d+)% user"#, options: .regularExpression) {
            // swiftlint:disable:next identifier_name
            if let val = Double(output[range].components(separatedBy: "%").first ?? "") {
                return val
            }
        }
        return 0
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
            if let val = extract("Pages free")        { pagesFree = val }
            if let val = extract("Pages active")      { pagesActive = val }
            if let val = extract("Pages inactive")    { pagesInactive = val }
            if let val = extract("Pages wired down")  { pagesWired = val }
        }
        let total = pagesFree + pagesActive + pagesInactive + pagesWired
        guard total > 0 else { return 0 }
        let used = pagesActive + pagesWired
        return (used / total) * 100
    }
}
// swiftlint:enable missing_docs
