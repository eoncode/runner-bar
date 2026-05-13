// swiftlint:disable line_length
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
/// Extension providing shell-based sampling helpers for `RunnerMetrics`.
extension RunnerMetrics {
    /// Samples CPU and memory for the first `Runner.Worker` process whose
    /// command line contains `runnerName`.
    /// Returns `nil` if no match or parse fails.
    static func sample(for runnerName: String) -> RunnerMetrics? {
        let output = shell("ps aux")
        for line in output.components(separatedBy: "\n") {
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

// MARK: - allWorkerMetrics
/// Returns CPU/MEM metrics for every `Runner.Worker` process found in `ps aux`,
/// in the order they appear.
/// Used by `RunnerStore.fetchAndEnrichRunners()` to assign metrics to runners
/// by slot index.
func allWorkerMetrics() -> [RunnerMetrics] {
    let output = shell("ps aux")
    var result: [RunnerMetrics] = []
    for line in output.components(separatedBy: "\n") {
        guard line.contains("Runner.Worker") else { continue }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 3,
              let cpu = Double(parts[2]),
              let mem = Double(parts[3]) else { continue }
        result.append(RunnerMetrics(cpu: cpu, mem: mem))
    }
    return result
}
// swiftlint:enable line_length
