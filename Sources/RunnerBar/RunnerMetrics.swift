import Foundation

struct RunnerMetrics {
    let cpu: Int
    let mem: Int
}

/// Reads CPU+MEM for a busy runner by summing all Runner.Worker and
/// Runner.Listener processes, then dividing by the number of busy runners.
/// This works regardless of whether the runner name appears in ps args.
func fetchMetrics(for runnerName: String, busyCount: Int) -> RunnerMetrics? {
    // Collect cpu+mem from all runner-related processes
    let output = shell("ps -eo pcpu,pmem,comm | grep -E 'Runner\\.(Worker|Listener)' | grep -v grep")
    guard !output.isEmpty else { return nil }
    var totalCPU = 0.0
    var totalMEM = 0.0
    var count = 0
    for line in output.components(separatedBy: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let cpu = Double(parts[0]),
              let mem = Double(parts[1]) else { continue }
        totalCPU += cpu
        totalMEM += mem
        count += 1
    }
    guard count > 0 else { return nil }
    let divisor = max(busyCount, 1)
    return RunnerMetrics(
        cpu: Int((totalCPU / Double(divisor)).rounded()),
        mem: Int((totalMEM / Double(divisor)).rounded())
    )
}
