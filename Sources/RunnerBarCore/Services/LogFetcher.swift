// LogFetcher.swift
// RunnerBarCore
import Foundation
import os

// MARK: - Filesystem path constants

/// Absolute path to the system `unzip` binary, always present on macOS.
private let unzipBinaryPath = "/usr/bin/unzip" // NOSONAR — fixed OS path

// MARK: - Job log (plain text, 1 call)

/// Fetches the full plain-text log for a single job.
///
/// `/actions/jobs/{id}/logs` 302-redirects to a short-lived S3 URL; the transport follows it.
/// Returns `nil` when `scope` is not in `owner/repo` form, the request fails,
/// or the response body looks like a JSON error object (starts with `"{"`). 
///
/// - Parameters:
///   - jobID: The GitHub Actions job ID.
///   - scope: The `owner/repo` string identifying the repository.
/// - Returns: Plain-text log content, or `nil` on failure.
public func fetchJobLog(jobID: Int, scope: String) async -> String? {
    guard scope.contains("/") else { return nil }
    guard let data = await ghRaw("repos/\(scope)/actions/jobs/\(jobID)/logs"),
          let text = String(data: data, encoding: .utf8) else { return nil }
    if text.hasPrefix("{") { return nil }
    return text
}

// MARK: - Action logs (ZIP per run, N calls)

/// Fetches and concatenates all job logs for every run in a group.
///
/// Issues one async task per run in parallel via `withTaskGroup`.
/// Each task retrieves a ZIP archive, extracts all `.txt` log files via `unzipLogs(_:)`,
/// and collects the results. The final output is sorted by filename for stable ordering.
///
/// - Parameter group: The `WorkflowActionGroup` whose runs should be fetched.
/// - Returns: A single concatenated string with `=== <name> ===` section headers,
///   or `nil` if `scope` is invalid, `runs` is empty, or all fetches fail.
public func fetchActionLogs(group: WorkflowActionGroup) async -> String? {
    let scope = group.repo
    guard scope.contains("/") else { return nil }
    let runIDs = group.runs.map { $0.id }
    guard !runIDs.isEmpty else { return nil }

    let parts: [(name: String, text: String)] = await withTaskGroup(
        of: [(name: String, text: String)].self
    ) { taskGroup in
        for runID in runIDs {
            taskGroup.addTask {
                guard let data = await ghRaw("repos/\(scope)/actions/runs/\(runID)/logs") else {
                    return []
                }
                return await unzipLogs(data)
            }
        }
        var collected: [(name: String, text: String)] = []
        for await result in taskGroup {
            collected.append(contentsOf: result)
        }
        return collected
    }

    guard !parts.isEmpty else { return nil }
    return parts
        .sorted { $0.name < $1.name }
        .map { "=== \($0.name) ===\n\($0.text)" }
        .joined(separator: "\n\n")
}

// MARK: - ZIP extraction (uses /usr/bin/unzip — always available on macOS)

/// Extracts all `.txt` files from a ZIP blob and returns `(name, text)` pairs.
///
/// Writes the ZIP to a unique temporary directory, runs `/usr/bin/unzip -q` via
/// `ProcessRunner.runAsync`, then enumerates the output directory for `.txt` files.
/// The temporary directory is always removed on return via `defer`.
///
/// The directory enumeration is materialised into an `[URL]` array *before* any
/// `await`, because `FileManager.DirectoryEnumerator.makeIterator` is unavailable
/// from async contexts (Swift concurrency restriction).
///
/// - Parameter zipData: Raw ZIP archive bytes as returned by the GitHub logs API.
/// - Returns: An array of `(name, text)` tuples where `name` is the archive-relative
///   path without the `.txt` extension (e.g. `"1_Build"` for `1_Build.txt`) and
///   `text` is the file content. Returns `[]` if the write, unzip, or enumeration
///   step fails.
public func unzipLogs(_ zipData: Data) async -> [(name: String, text: String)] {
    let fileManager = FileManager.default
    let tmp = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let zipFile = tmp.appendingPathComponent("logs.zip")
    defer { try? fileManager.removeItem(at: tmp) }
    do {
        try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
        try zipData.write(to: zipFile)
    } catch { return [] }
    let result = await ProcessRunner.runAsync(
        executableURL: URL(fileURLWithPath: unzipBinaryPath),
        arguments: ["-q", zipFile.path, "-d", tmp.path]
    )
    guard result.exitCode == 0 else { return [] }
    // Materialise the enumerator into a plain [URL] array before any suspension
    // point — FileManager.DirectoryEnumerator.makeIterator is unavailable from
    // async contexts (Swift concurrency restriction).
    guard let enumerator = fileManager.enumerator(at: tmp, includingPropertiesForKeys: nil) else { return [] }
    let txtURLs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "txt" }
    var results: [(name: String, text: String)] = []
    for url in txtURLs {
        let relative = url.path.replacingOccurrences(of: tmp.path + "/", with: "")
        let name = URL(fileURLWithPath: relative).deletingPathExtension().path
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            results.append((name: name, text: text))
        }
    }
    return results
}
