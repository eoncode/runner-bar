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

// MARK: - Parse helpers

/// Converts newline-separated `pgrep` stdout into a comma-joined PID list
/// suitable for passing to `ps -p`.
///
/// Uses `.split(separator:)` which drops empty subsequences natively,
/// so a trailing newline in `pgrep` output produces no spurious empty PID.
///
/// - Parameter output: Raw stdout from a `pgrep` invocation.
/// - Returns: A non-empty comma-joined string of PIDs, or `nil` when the
///   input contains no non-empty lines.
private func parsePIDs(_ output: String) -> String? {
    let pids = output
        .split(separator: "\n")
        .map(String.init)
        .joined(separator: ",")
    return pids.isEmpty ? nil : pids
}

/// Parses `ps -o pid,%cpu,%mem,command` output into an array of `RunnerMetrics`.
///
/// The first (header) line is always skipped. Subsequent lines are split with
/// `.split(separator:omittingEmptySubsequences:)`, consistent with `parsePIDs`.
/// Each non-blank line must supply at least three columns: PID (index 0),
/// %CPU (index 1), and %MEM (index 2). The command column (index 3) is
/// intentionally **not** required: `ps` may omit it for zombie or kernel
/// threads, yet their cpu/mem values are still valid and should be counted.
/// (The previous `allWorkerMetrics` implementation used `parts.count > 3`,
/// which was over-strict for that reason; the threshold is consciously
/// unified at `> 2` here.)
///
/// Each successfully parsed line is logged with its cpu, mem, and the first
/// three words of the command column (when present) so that unexpected
/// process matches surface clearly in diagnostics.
///
/// Lines that cannot be parsed are logged under the given `context` tag and
/// silently skipped.
///
/// - Parameters:
///   - output: Raw stdout returned by the `ps` invocation.
///   - context: Caller name used as the log-line prefix (e.g. `"metricsForRunner"`).
/// - Returns: An array of `RunnerMetrics` values; empty when no parseable
///   lines are found.
private func parsePSOutput(_ output: String, context: String) -> [RunnerMetrics] {
    // Pass omittingEmptySubsequences: false so the header line is always a
    // stable index-0 element and .dropFirst() reliably skips it. Blank lines
    // that survive into the loop are filtered by the guard below.
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
    var results: [RunnerMetrics] = []
    for line in lines {
        // Require PID + %cpu + %mem (indices 0–2). The command column (index 3)
        // is not read for values and is not required — see doc-comment above.
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 2, let cpu = Double(parts[1]), let mem = Double(parts[2]) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log("\(context) › failed to parse line: \(line)")
            }
            continue
        }
        // Log the command tail so unexpected process matches are diagnosable.
        let tail = parts.count > 3 ? parts.dropFirst(3).prefix(3).joined(separator: " ") : "<no command>"
        log("\(context) › found process cpu=\(cpu) mem=\(mem): \(tail)")
        results.append(RunnerMetrics(cpu: cpu, mem: mem))
    }
    return results
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
    guard let pidList = parsePIDs(pidsOutput) else {
        log("metricsForRunner › no processes found for installPath=\(installPath)")
        return nil
    }
    log("metricsForRunner › found pids=\(pidList) for installPath=\(installPath)")
    let output = await runProcess(psPath, ["-p", pidList, "-o", psOutputFormat], timeout: 5)
    guard !output.isEmpty else {
        log("metricsForRunner › ps returned empty for installPath=\(installPath)")
        return nil
    }
    let metrics = parsePSOutput(output, context: "metricsForRunner")
    guard !metrics.isEmpty else {
        log("metricsForRunner › no parseable lines for installPath=\(installPath)")
        return nil
    }
    let result = RunnerMetrics(
        cpu: metrics.reduce(0) { $0 + $1.cpu },
        mem: metrics.reduce(0) { $0 + $1.mem }
    )
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
    let pidsOutput = await runProcess(pgrepPath, ["-f", pgrepWorkerPattern], timeout: 3)
    guard let pidList = parsePIDs(pidsOutput) else {
        log("allWorkerMetrics › no Runner.Worker / Runner.Listener processes found — returning []")
        return []
    }
    log("allWorkerMetrics › found pids=\(pidList)")
    let output = await runProcess(psPath, ["-p", pidList, "-o", psOutputFormat], timeout: 5)
    log("allWorkerMetrics › ps returned — outputBytes=\(output.count) isEmpty=\(output.isEmpty)")
    guard !output.isEmpty else {
        log("allWorkerMetrics › ps returned empty — returning []")
        return []
    }
    let results = parsePSOutput(output, context: "allWorkerMetrics")
    log("allWorkerMetrics › scanning \(results.count) result(s)")
    let sorted = results.sorted { $0.cpu > $1.cpu }
    log("allWorkerMetrics › EXIT — returning \(sorted.count) metric(s)")
    return sorted
}
