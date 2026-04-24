import Foundation

struct RunnerMetrics {
    let cpu: Double
    let mem: Double
}

/// Returns the CPU% and MEM% for the `Runner.Worker` process whose command-line
/// arguments contain `runnerName`.
///
/// Uses `ps aux` (full argument list) so we can match by name — `ps -eo comm`
/// truncates to 15 chars and never includes args, making per-runner attribution
/// impossible. Each runner's Worker process carries the runner name in its path
/// or `--name` flag, giving us a reliable per-process match.
func fetchMetrics(for runnerName: String) -> RunnerMetrics? {
    // ps aux columns: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND…
    let output = shell("ps aux", timeout: 5)
    guard !output.isEmpty else {
        log("fetchMetrics › ps aux returned empty output")
        return nil
    }

    var totalCPU = 0.0
    var totalMEM = 0.0
    var matchCount = 0

    for line in output.components(separatedBy: "\n") {
        // Must be a Runner.Worker or Runner.Listener process
        guard line.contains("Runner.Worker") || line.contains("Runner.Listener") else { continue }
        // Must reference this runner's name somewhere in the full command
        guard line.lowercased().contains(runnerName.lowercased()) else { continue }

        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        // ps aux layout: [0]=USER [1]=PID [2]=%CPU [3]=%MEM ...
        guard parts.count > 3,
              let cpu = Double(parts[2]),
              let mem = Double(parts[3]) else { continue }

        log("fetchMetrics › \(runnerName) matched process: cpu=\(cpu) mem=\(mem)")
        totalCPU += cpu
        totalMEM += mem
        matchCount += 1
    }

    guard matchCount > 0 else {
        log("fetchMetrics › no matching process found for runner: \(runnerName)")
        return nil
    }

    // Sum across Worker+Listener for this runner (usually 1-2 processes)
    return RunnerMetrics(cpu: totalCPU, mem: totalMEM)
}
