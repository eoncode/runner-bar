// RunnerMetrics.swift
// RunnerBar
import Foundation

/// CPU and memory utilisation snapshot for a single `Runner.Worker` process.
public struct RunnerMetrics: Equatable {
    /// The cpu constant.
    public let cpu: Double
    /// The mem constant.
    public let mem: Double

    /// Creates a new instance.
    public init(cpu: Double, mem: Double) {
        self.cpu = cpu
        self.mem = mem
    }
}

// MARK: - Direct-execution helper

/// Runs an executable at `path` with `arguments` directly — no shell wrapper.
/// Avoids `/bin/zsh -c` overhead, shell quoting edge-cases, and command-injection risk.
/// Timeout is enforced via `DispatchSemaphore`; the process is terminated on expiry.
/// Returns trimmed stdout, or an empty string on timeout / launch failure.
private func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    do { try process.run() } catch {
        log("runProcess › launch failed path=\(path) args=\(arguments) error=\(error)")
        return ""
    }
    let sema = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async { [sema] in
        process.waitUntilExit()
        sema.signal()
    }
    guard sema.wait(timeout: .now() + timeout) == .success else {
        log("runProcess › timeout after \(timeout)s — terminating \(path)")
        process.terminate()
        return ""
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// MARK: - Per-runner metrics

/// Returns CPU+MEM metrics for the `Runner.Worker` / `Runner.Listener` processes
/// that belong to the runner installed at `installPath`.
///
/// Matches by checking the process command line contains `installPath`, so each
/// runner is identified individually — not by slot-index approximation.
/// Sums CPU and MEM across all matching processes (Worker + Listener) for the runner.
/// Returns `nil` when no matching process is found.
public func metricsForRunner(installPath: String) -> RunnerMetrics? {
    log("metricsForRunner › ENTER installPath=\(installPath)")
    let pidsOutput = runProcess("/usr/bin/pgrep", ["-f", installPath], timeout: 3)
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
    let output = runProcess("/bin/ps", ["-p", pidList, "-o", "pid,%cpu,%mem,command"], timeout: 5)
    guard !output.isEmpty else {
        log("metricsForRunner › ps returned empty for installPath=\(installPath)")
        return nil
    }
    let lines = output.components(separatedBy: "\n").dropFirst() // drop header
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

/// Performs the allWorkerMetrics operation.
public func allWorkerMetrics() -> [RunnerMetrics] {
    log("allWorkerMetrics › ENTER — using direct pgrep + ps (no shell wrapper)")

    // Step 1: find matching PIDs only — fast, doesn't walk full process table.
    // Dots are escaped (\.) so pgrep treats them as literal characters,
    // not regex wildcards — avoids false matches like 'RunnerXWorker'.
    let pidsOutput = runProcess(
        "/usr/bin/pgrep",
        ["-f", "Runner\\.Worker|Runner\\.Listener"],
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

    // Step 2: ps scoped to only those PIDs
    let output = runProcess("/bin/ps", ["-p", pidList, "-o", "pid,%cpu,%mem,command"], timeout: 5)
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
