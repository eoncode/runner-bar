import Foundation

/// CPU and memory utilisation snapshot for a single `Runner.Worker` process.
struct RunnerMetrics {
    let cpu: Double
    let mem: Double
}

/// Returns CPU+MEM metrics for the `Runner.Worker` / `Runner.Listener` processes
/// that belong to the runner installed at `installPath`.
///
/// Matches by checking the process command line contains `installPath`, so each
/// runner is identified individually — not by slot-index approximation.
/// Sums CPU and MEM across all matching processes (Worker + Listener) for the runner.
/// Returns `nil` when no matching process is found.
func metricsForRunner(installPath: String) -> RunnerMetrics? {
    log("metricsForRunner › ENTER installPath=\(installPath)")
    // Escape single-quotes in path for shell safety
    let escaped = installPath.replacingOccurrences(of: "'", with: "'\\''")
    let pidsOutput = shell("pgrep -f '\(escaped)'", timeout: 3)
    guard !pidsOutput.isEmpty else {
        log("metricsForRunner › no processes found for installPath=\(installPath)")
        return nil
    }
    let pidList = pidsOutput
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.isEmpty }
        .joined(separator: ",")
    log("metricsForRunner › found pids=\(pidList) for installPath=\(installPath)")
    let output = shell("ps -p \(pidList) -o pid,%cpu,%mem,command", timeout: 5)
    guard !output.isEmpty else {
        log("metricsForRunner › ps returned empty for installPath=\(installPath)")
        return nil
    }
    let lines = output.components(separatedBy: "\n").dropFirst()
    var totalCPU = 0.0
    var totalMEM = 0.0
    var count = 0
    for line in lines {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 2,
              let cpu = Double(parts[1]),
              let mem = Double(parts[2]) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log("metricsForRunner › failed to parse line: \(line)")
            }
            continue
        }
        totalCPU += cpu
        totalMEM += mem
        count += 1
    }
    guard count > 0 else {
        log("metricsForRunner › no parseable lines for installPath=\(installPath)")
        return nil
    }
    let result = RunnerMetrics(cpu: totalCPU, mem: totalMEM)
    log("metricsForRunner › EXIT cpu=\(result.cpu) mem=\(result.mem) installPath=\(installPath)")
    return result
}

func allWorkerMetrics() -> [RunnerMetrics] {
    log("allWorkerMetrics › ENTER — using pgrep + targeted ps")

    // Step 1: find matching PIDs only — fast, doesn't walk full process table
    let pidsOutput = shell("pgrep -f 'Runner\\.Worker|Runner\\.Listener'", timeout: 3)
    guard !pidsOutput.isEmpty else {
        log("allWorkerMetrics › no Runner.Worker / Runner.Listener processes found — returning []")
        return []
    }

    let pidList = pidsOutput
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.isEmpty }
        .joined(separator: ",")

    log("allWorkerMetrics › found pids=\(pidList)")

    // Step 2: ps scoped to only those PIDs
    let output = shell("ps -p \(pidList) -o pid,%cpu,%mem,command", timeout: 5)
    log("allWorkerMetrics › ps returned — outputBytes=\(output.count) isEmpty=\(output.isEmpty)")
    guard !output.isEmpty else {
        log("allWorkerMetrics › ps returned empty — returning []")
        return []
    }

    let lines = output.components(separatedBy: "\n").dropFirst() // drop header
    log("allWorkerMetrics › scanning \(lines.count) line(s)")

    var results: [RunnerMetrics] = []
    for line in lines {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 3,
              let cpu = Double(parts[1]),
              let mem = Double(parts[2]) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log("allWorkerMetrics › failed to parse line: \(line)")
            }
            continue
        }
        let tail = parts.dropFirst(3).prefix(3).joined(separator: " ")
        log("allWorkerMetrics › found process cpu=\(cpu) mem=\(mem): \(tail)")
        results.append(RunnerMetrics(cpu: cpu, mem: mem))
    }

    let sorted = results.sorted { $0.cpu > $1.cpu }
    log("allWorkerMetrics › EXIT — returning \(sorted.count) metric(s)")
    return sorted
}
