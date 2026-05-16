import Combine
import Foundation
import SwiftUI

// MARK: - SystemStatsViewModel

/// ObservableObject that polls system stats and maintains rolling history arrays
/// for the sparkline graphs in PopoverHeaderView.
final class SystemStatsViewModel: ObservableObject {
    /// Latest point-in-time stats snapshot.
    @Published var stats: SystemStats = .zero
    /// Rolling CPU utilisation history (0.0–1.0), newest last.
    @Published var cpuHistory: [Double] = []
    /// Rolling memory utilisation history (0.0–1.0), newest last.
    @Published var memHistory: [Double] = []
    /// Rolling disk utilisation history (0.0–1.0), newest last.
    @Published var diskHistory: [Double] = []

    private var timer: Timer?
    private let maxSamples = 30

    /// Starts the polling timer (every 2 s).
    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Stops the polling timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let snapshot = SystemStats.current()
            await MainActor.run {
                self.stats = snapshot
                self.append(value: snapshot.cpuPct / 100.0, to: &self.cpuHistory)
                let memPct = snapshot.memTotalGB > 0
                    ? snapshot.memUsedGB / snapshot.memTotalGB
                    : 0.0
                self.append(value: memPct, to: &self.memHistory)
                let diskPct = snapshot.diskTotalGB > 0
                    ? snapshot.diskUsedGB / snapshot.diskTotalGB
                    : 0.0
                self.append(value: diskPct, to: &self.diskHistory)
            }
        }
    }

    private func append(value: Double, to array: inout [Double]) {
        array.append(max(0, min(1, value)))
        if array.count > maxSamples { array.removeFirst(array.count - maxSamples) }
    }
}

// MARK: - SystemStatsPoller2

/// Legacy background poller kept for any remaining observer-pattern consumers.
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
        SystemStatsSnapshot(cpuPercent: fetchCPU(), memPercent: fetchMem())
    }

    private static func fetchCPU() -> Double {
        let output = shell("top -l 1 -s 0 | grep 'CPU usage'", timeout: 5)
        guard let range = output.range(of: #"(\d+\.\d+)% user"#, options: .regularExpression) else { return 0 }
        return Double(output[range].components(separatedBy: "%").first ?? "") ?? 0
    }

    private static func fetchMem() -> Double {
        let output = shell("vm_stat", timeout: 5)
        var pagesFree = 0.0, pagesActive = 0.0, pagesInactive = 0.0, pagesWired = 0.0
        for line in output.components(separatedBy: "\n") {
            func extract(_ key: String) -> Double? {
                guard line.contains(key),
                      let val = line.components(separatedBy: ":").last?
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: ".", with: "")
                else { return nil }
                return Double(val)
            }
            if let val = extract("Pages free")       { pagesFree     = val }
            if let val = extract("Pages active")     { pagesActive   = val }
            if let val = extract("Pages inactive")   { pagesInactive = val }
            if let val = extract("Pages wired down") { pagesWired    = val }
        }
        let total = pagesFree + pagesActive + pagesInactive + pagesWired
        guard total > 0 else { return 0 }
        return ((pagesActive + pagesWired) / total) * 100
    }
}
