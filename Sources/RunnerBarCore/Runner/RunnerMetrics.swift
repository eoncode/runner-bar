// RunnerMetrics.swift
// RunnerBarCore
import Foundation

/// CPU and memory utilisation snapshot for a single `Runner.Worker` process.
public struct RunnerMetrics: Equatable, Sendable {
    /// CPU utilisation percentage for this runner process.
    public let cpu: Double
    /// Memory utilisation percentage for this runner process.
    public let mem: Double

    /// Creates a `RunnerMetrics` snapshot.
    /// - Parameters:
    ///   - cpu: CPU utilisation percentage.
    ///   - mem: Memory utilisation percentage.
    public init(cpu: Double, mem: Double) {
        self.cpu = cpu
        self.mem = mem
    }
}

// MARK: - System binary paths
/// Fixed OS path to `pgrep`; extracted to suppress SonarCloud hardcoded-URI warnings.
private let pgrepPath = "/usr/bin/pgrep" // NOSONAR — fixed OS path
/// Fixed OS path to `ps`; extracted to suppress SonarCloud hardcoded-URI warnings.
private let psPath = "/bin/ps" // NOSONAR — fixed OS path
/// `ps -o` column format used when sampling process CPU and memory.
private let psOutputFormat = "pid,%cpu,%mem,command" // NOSONAR — fixed ps format string
/// `pgrep -f` pattern that matches all GitHub runner worker and listener processes.
private let pgrepWorkerPattern = #"Runner\.Worker|Runner\.Listener"# // NOSONAR — fixed process filter

// MARK: - Direct-execution helper

/// Runs an executable at `path` with `arguments` directly via `ProcessRunner.runAsync`.
/// Avoids `/bin/zsh -c` overhead, shell quoting edge-cases, and command-injection risk.
/// Returns trimmed stdout, or an empty string on timeout / launch failure.
private func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) async -> String {
    let result = await ProcessRunner.runAsync(
        executableURL: URL(fileURLWithPath: path),
        arguments: arguments,
        timeout: timeout
    )
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Per-runner metrics

/// Returns CPU and memory metrics for the `Runner.Worker` / `Runner.Listener` processes
/// that belong to the runner installed at `installPath`.
///
/// Matches by checking the process command line contains `installPath`, so each
/// runner is identified individually. Sums CPU and MEM across all matching processes.
/// Returns `nil` when no matching process is found.
/// - Parameter installPath: Absolute path to the runner installation directory.
/// - Returns: A `RunnerMetrics` snapshot, or `nil` if no matching process exists.
public func metricsForRunner(installPath: String) async -> RunnerMetrics? {
    log("metricsForRunner › ENTER installPath=\(installPath)")
    let pidsOutput = await runProcess(pgrepPath, ["-f", installPath], timeout: 3)
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
    let output = await runProcess(psPath, ["-p", pidList, "-o", psOutputFormat], timeout: 5)
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
        guard parts.count > 2, let cpu = Double(parts[1]), let mem = Double(parts[2]) else {
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

// MARK: - All-worker metrics

/// Returns CPU and memory metrics for all `Runner.Worker` and `Runner.Listener`
/// processes currently running on this machine, sorted by descending CPU usage.
///
/// Uses `pgrep` to find matching PIDs, then `ps` to read their resource usage.
/// Returns an empty array when no matching processes are found.
/// - Returns: Array of `RunnerMetrics` sorted by descending CPU utilisation.
public func allWorkerMetrics() async -> [RunnerMetrics] {
    log("allWorkerMetrics › ENTER — using direct pgrep + ps (no shell wrapper)")
    let pidsOutput = await runProcess(
        pgrepPath,
        ["-f", pgrepWorkerPattern],
        timeout: 3
    )
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
    let output = await runProcess(psPath, ["-p", pidList, "-o", psOutputFormat], timeout: 5)
    log("allWorkerMetrics › ps returned — outputBytes=\(output.count) isEmpty=\(output.isEmpty)")
    guard !output.isEmpty else {
        log("allWorkerMetrics › ps returned empty — returning []")
        return []
    }
    let lines = output.components(separatedBy: "\n").dropFirst()
    log("allWorkerMetrics › scanning \(lines.count) line(s)")
    var results: [RunnerMetrics] = []
    for line in lines {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 3, let cpu = Double(parts[1]), let mem = Double(parts[2]) else {
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
