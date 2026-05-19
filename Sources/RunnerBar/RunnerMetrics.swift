import Foundation
// swiftlint:disable vertical_whitespace_closing_braces

/// CPU and memory utilisation snapshot for a single `Runner.Worker` process.
struct RunnerMetrics {
    let cpu: Double
    let mem: Double
}

func allWorkerMetrics() -> [RunnerMetrics] {
    log("allWorkerMetrics › ENTER — calling shell(ps aux, timeout:5)")
    let output = shell("ps aux", timeout: 5)
    log("allWorkerMetrics › shell() returned — outputBytes=\(output.count) isEmpty=\(output.isEmpty)")
    guard !output.isEmpty else {
        log("allWorkerMetrics › ps aux returned empty — returning []")
        return []
    }
    let lines = output.components(separatedBy: "\n")
    log("allWorkerMetrics › ps aux returned \(lines.count) lines — scanning for Runner.Worker / Runner.Listener")
    var results: [RunnerMetrics] = []
    for line in lines {
        guard line.contains("Runner.Worker") || line.contains("Runner.Listener") else { continue }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 3,
              let cpu = Double(parts[2]),
              let mem = Double(parts[3]) else {
            log("allWorkerMetrics › failed to parse line: \(line)")
            continue
        }
        let tail = parts.dropFirst(10).prefix(3).joined(separator: " ")
        log("allWorkerMetrics › found process cpu=\(cpu) mem=\(mem): \(tail)")
        results.append(RunnerMetrics(cpu: cpu, mem: mem))
    }
    let sorted = results.sorted { $0.cpu > $1.cpu }
    log("allWorkerMetrics › EXIT — returning \(sorted.count) metric(s)")
    return sorted
}
