import Foundation

// MARK: - RunnerMetrics

/// CPU and memory utilisation sampled from `ps aux` for a single runner process.
struct RunnerMetrics: Codable {
    /// CPU usage percentage (0–100+, can exceed 100 on multi-core).
    let cpu: Double
    /// Memory usage as a percentage of total RAM.
    let mem: Double
}

// MARK: - RunnerMetrics + ps

extension RunnerMetrics {
    /// Samples CPU and memory for the first `Runner.Worker` process whose
    /// command line contains `runnerName`.
    ///
    /// Returns `nil` if no matching process is found or parsing fails.
    static func sample(for runnerName: String) -> RunnerMetrics? {
        let output = shell("ps aux")
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            guard line.contains("Runner.Worker"),
                  line.contains(runnerName) else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 3,
                  let cpu = Double(parts[2]),
                  let mem = Double(parts[3]) else { continue }
            return RunnerMetrics(cpu: cpu, mem: mem)
        }
        return nil
    }
}
