// LogFetcher.swift
// RunnerBarCore
import Foundation
import os

// MARK: - Filesystem path constants
/// The unzipBinaryPath constant.
private let unzipBinaryPath = "/usr/bin/unzip"

/// Fetches raw bytes from a GitHub API endpoint via URLSession.
/// Log endpoints 302-redirect to S3; URLSession follows the redirect automatically.
/// Returns nil when no token is available or the request fails.
private func ghRaw(_ endpoint: String, timeout: TimeInterval = 60) -> Data? {
    ghRawTransport()(endpoint)
}

// MARK: - Job log (plain text, 1 call)

/// Fetches the full plain-text log for a single job.
/// `/actions/jobs/{id}/logs` 302-redirects to a short-lived S3 URL; gh follows it.
public func fetchJobLog(jobID: Int, scope: String) -> String? {
    guard scope.contains("/") else { return nil }
    guard let data = ghRaw("repos/\(scope)/actions/jobs/\(jobID)/logs"),
          let text = String(data: data, encoding: .utf8) else { return nil }
    if text.hasPrefix("{") { return nil }
    return text
}

// MARK: - Action logs (ZIP per run, N calls)

/// Fetches and concatenates all job logs for every run in a group.
/// Each run: 1 API call → ZIP → extract → read .txt files.
public func fetchActionLogs(group: WorkflowActionGroup) -> String? {
    let scope = group.repo
    guard scope.contains("/") else { return nil }
    let runIDs = group.runs.map { $0.id }
    guard !runIDs.isEmpty else { return nil }
    let parts = OSAllocatedUnfairLock<[(name: String, text: String)]>(initialState: [])
    let dispatchGroup = DispatchGroup()
    for runID in runIDs {
        dispatchGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { dispatchGroup.leave() }
            guard let data = ghRaw("repos/\(scope)/actions/runs/\(runID)/logs") else { return }
            let extracted = unzipLogs(data)
            parts.withLock { $0.append(contentsOf: extracted) }
        }
    }
    dispatchGroup.wait()
    let finalParts = parts.withLock { $0 }
    guard !finalParts.isEmpty else { return nil }
    return finalParts
        .sorted { $0.name < $1.name }
        .map { "=== \($0.name) ===\n\($0.text)" }
        .joined(separator: "\n\n")
}

// MARK: - ZIP extraction (uses /usr/bin/unzip — always available on macOS)

/// Extracts all `.txt` files from a ZIP blob and returns `(name, text)` pairs.
public func unzipLogs(_ zipData: Data) -> [(name: String, text: String)] {
    let fileManager = FileManager.default
    let tmp = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let zipFile = tmp.appendingPathComponent("logs.zip")
    defer { try? fileManager.removeItem(at: tmp) }
    do {
        try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
        try zipData.write(to: zipFile)
    } catch { return [] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: unzipBinaryPath)
    proc.arguments = ["-q", zipFile.path, "-d", tmp.path]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return [] }
    guard let enumerator = fileManager.enumerator(at: tmp, includingPropertiesForKeys: nil) else { return [] }
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
