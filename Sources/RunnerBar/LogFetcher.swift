import Foundation

// MARK: - Raw binary/text fetch via gh CLI

/// Calls `gh api` with `Accept: application/vnd.github.v3.raw` so log endpoints
/// return the raw redirected body (plain text for jobs, ZIP bytes for runs)
/// instead of the default JSON wrapper. Mirrors the pattern used by
/// `fetchStepLog` in GitHub.swift but returns raw `Data` for binary support.
private func ghRaw(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    guard let gh = ghBinaryPath() else {
        log("ghRaw › gh not found")
        return nil
    }
    let task = Process()
    let pipe = Pipe()
    task.executableURL  = URL(fileURLWithPath: gh)
    task.arguments      = ["api", endpoint, "--header", "Accept: application/vnd.github.v3.raw"]
    task.standardOutput = pipe
    task.standardError  = Pipe()
    var outputData = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock(); outputData.append(chunk); lock.unlock()
    }
    do { try task.run() } catch {
        log("ghRaw › launch error: \(error)")
        pipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }
    let timeoutItem = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    task.waitUntilExit()
    timeoutItem.cancel()
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
    log("ghRaw › \(endpoint) → \(outputData.count)b exit \(task.terminationStatus)")
    return outputData.isEmpty ? nil : outputData
}

// MARK: - Job log (plain text, 1 call)

/// Fetches the full plain-text log for a single job.
/// `/actions/jobs/{id}/logs` 302-redirects to a short-lived S3 URL; gh follows it.
func fetchJobLog(jobID: Int, scope: String) -> String? {
    guard scope.contains("/") else { return nil }
    guard let data = ghRaw("repos/\(scope)/actions/jobs/\(jobID)/logs"),
          let text = String(data: data, encoding: .utf8)
    else { return nil }
    if text.hasPrefix("{") { return nil }  // error JSON, not a real log
    return text
}

// MARK: - Action logs (ZIP per run, N calls)

/// Fetches and concatenates all job logs for every run in a group.
/// Each run: 1 API call → ZIP → extract → read .txt files.
func fetchActionLogs(group: ActionGroup) -> String? {
    let scope = group.repo
    guard scope.contains("/") else { return nil }
    let runIDs = group.runs.map { $0.id }
    guard !runIDs.isEmpty else { return nil }

    var parts: [(name: String, text: String)] = []
    let lock = NSLock()
    let dg = DispatchGroup()

    for runID in runIDs {
        dg.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { dg.leave() }
            guard let data = ghRaw("repos/\(scope)/actions/runs/\(runID)/logs") else { return }
            let extracted = unzipLogs(data)
            lock.lock()
            parts.append(contentsOf: extracted)
            lock.unlock()
        }
    }

    dg.wait()
    guard !parts.isEmpty else { return nil }

    return parts
        .sorted { $0.name < $1.name }
        .map { "=== \($0.name) ===\n\($0.text)" }
        .joined(separator: "\n\n")
}

// MARK: - ZIP extraction (uses /usr/bin/unzip — always available on macOS)

func unzipLogs(_ zipData: Data) -> [(name: String, text: String)] {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let zipFile = tmp.appendingPathComponent("logs.zip")
    defer { try? fm.removeItem(at: tmp) }

    do {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try zipData.write(to: zipFile)
    } catch { return [] }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments = ["-q", zipFile.path, "-d", tmp.path]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError  = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        return []
    }

    guard let enumerator = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) else { return [] }
    var results: [(name: String, text: String)] = []
    for case let url as URL in enumerator where url.pathExtension == "txt" {
        let relative = url.path.replacingOccurrences(of: tmp.path + "/", with: "")
        let name = URL(fileURLWithPath: relative).deletingPathExtension().path
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            results.append((name: name, text: text))
        }
    }
    return results
}
