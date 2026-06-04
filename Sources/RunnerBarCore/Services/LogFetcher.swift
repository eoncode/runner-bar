// LogFetcher.swift
// RunnerBarCore
import Foundation
import os

// MARK: - Filesystem path constants

/// Absolute path to the system `unzip` binary, always present on macOS.
private let unzipBinaryPath = "/usr/bin/unzip" // NOSONAR — fixed OS path

// MARK: - Transport shim

/// Fetches raw bytes from a GitHub API endpoint via the configured transport.
///
/// Delegates to `ghRawTransport()` so the underlying mechanism (URLSession or
/// `gh` CLI) can be swapped without touching call sites.
/// Log endpoints 302-redirect to S3; the transport follows the redirect automatically.
/// - Parameter endpoint: A relative GitHub REST path, e.g. `"repos/owner/repo/actions/jobs/123/logs"`.
/// - Parameter timeout: Reserved for transport implementations that support request timeouts.
///   The current transport shim does not consume this value.
/// - Returns: Raw response bytes, or `nil` when no token is available or the request fails.
private func ghRaw(_ endpoint: String, _  timeout: TimeInterval = 60) -> Data? {
    ghRawTransport()(endpoint)
}

// MARK: - Job log (plain text, 1 call)

/// Fetches the full plain-text log for a single job.
///
/// `/actions/jobs/{id}/logs` 302-redirects to a short-lived S3 URL; the transport follows it.
/// Returns `nil` when `scope` is not in `owner/repo` form, the request fails,
/// or the response body looks like a JSON error object (starts with `"{"`)
///
/// - Parameters:
///   - jobID: The GitHub Actions job ID.
///   - scope: The `owner/repo` string identifying the repository.
/// - Returns: Plain-text log content, or `nil` on failure.
public func fetchJobLog(jobID: Int, scope: String) -> String? {
    guard scope.contains("/") else { return nil }
    guard let data = ghRaw("repos/\(scope)/actions/jobs/\(jobID)/logs"),
          let text = String(data: data, encoding: .utf8) else { return nil }
    if text.hasPrefix("{") { return nil }
    return text
}

// MARK: - Action logs (ZIP per run, N calls)

/// Fetches and concatenates all job logs for every run in a group.
///
/// Issues one API call per run in parallel on `DispatchQueue.global(qos: .userInitiated)`.
/// Each call retrieves a ZIP archive, extracts all `.txt` log files via `unzipLogs(_:)`,
/// and appends the results to a shared accumulator guarded by `OSAllocatedUnfairLock`.
/// The final output is sorted by filename for stable ordering when names are unique.
///
/// This function is synchronous: it blocks the calling thread until all per-run fetches
/// complete. Do not call from the main thread for groups with many runs or slow connections.
/// - Parameter group: The `WorkflowActionGroup` whose runs should be fetched.
/// - Returns: A single concatenated string with `=== <name> ===` section headers,
///   or `nil` if `scope` is invalid, `runs` is empty, or all fetches fail.
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
///
/// Writes the ZIP to a unique temporary directory, runs `/usr/bin/unzip -q`,
/// then enumerates the output directory for `.txt` files. The temporary directory
/// is always removed on return via `defer`.
/// - Parameter zipData: Raw ZIP archive bytes as returned by the GitHub logs API.
/// - Returns: An array of `(name, text)` tuples where `name` is the archive-relative
///   path without the `.txt` extension (e.g. `"1_Build"` for `1_Build.txt`) and
///   `text` is the file content. Returns `[]` if the write, unzip, or enumeration
///   step fails.
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
