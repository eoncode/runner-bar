import Foundation

/// CPU and memory utilisation snapshot for a single `Runner.Worker` process.
/// Values are percentages sourced from the `%CPU` and `%MEM` columns of `ps aux`.
struct RunnerMetrics {
    /// CPU utilisation as a percentage (e.g. `12.5` means 12.5% of one core).
    let cpu: Double
    /// Memory utilisation as a percentage of total physical RAM (from `ps aux` `%MEM`).
    let mem: Double
}

/// Collects all Runner.Worker processes from `ps aux` and returns them
/// sorted by CPU% descending.
///
/// Mirrors ci-dash.py `runner_procs()` + `pair_runners()`: the runner name
/// does NOT appear in ps args, so name-based matching always fails.
/// Instead the caller assigns metrics by slot index (busy runners first).
func allWorkerMetrics() -> [RunnerMetrics] {
    let output = shell("ps aux", timeout: 5)
    guard !output.isEmpty else {
        log("allWorkerMetrics › ps aux returned empty")
        return []
    }

    var results: [RunnerMetrics] = []
    for line in output.components(separatedBy: "\n") {
        guard line.contains("Runner.Worker") || line.contains("Runner.Listener") else { continue }
        // ps aux columns: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND…
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        // swiftlint:disable:next identifier_name
        guard parts.count > 3,
              let cpu = Double(parts[2]),
              let mem = Double(parts[3]) else { continue }
        log("allWorkerMetrics › found process cpu=\(cpu) mem=\(mem): \(parts[10...].prefix(3).joined(separator: " "))")
        results.append(RunnerMetrics(cpu: cpu, mem: mem))
    }

    // Highest CPU first — matches ci-dash.py Worker ordering
    return results.sorted { $0.cpu > $1.cpu }
}
