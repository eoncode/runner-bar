// LocalRunnerScanner.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - LocalRunnerScanner

// swiftlint:disable:next type_body_length
/// Discovers locally-installed GitHub Actions self-hosted runners without
/// requiring a GitHub API token. Uses three complementary scan sources:
///
/// 1. **LaunchAgents** — `~/Library/LaunchAgents/actions.runner.*.plist`
///    Reads the `WorkingDirectory` key from each plist so the runner's exact
///    install path is known for any custom location. The plist label is also
///    used to derive a `gitHubUrl` fallback (`https://github.com/<owner>/<repo>`)
///    for runners whose `.runner` JSON omits the field (e.g. installed via
///    `svc.sh install`). The JSON is still authoritative when present.
///
/// 2. **`.runner` JSON files** — searches the known default install paths
///    PLUS any `WorkingDirectory` paths extracted from LaunchAgent plists.
///    Provides `gitHubUrl`, `runnerName`, `agentId`, `workFolder`,
///    `platform`, `platformArchitecture`, `agentVersion`, `ephemeral`. (#491)
///    Default roots: `~/actions-runner`, `~/runner`, `~/github-runner`,
///    `/opt/actions-runner`, `/opt/runner`, `/usr/local/actions-runner`,
///    `/usr/local/runner` up to depth 6.
///
/// 3. **Live service check** — `launchctl list` filtered in-process for `actions.runner`
///    Flags which runners currently have an active launchd service.
struct LocalRunnerScanner {

    // MARK: - .runner JSON schema

    /// A value type representing RunnerJSON.
    private struct RunnerJSON: Decodable {
        /// The gitHubUrl constant.
        let gitHubUrl: String?
        /// The runnerName constant.
        let runnerName: String?
        /// The agentId constant.
        let agentId: Int?
        /// The workFolder constant.
        let workFolder: String?
        // #491 — additional fields present in the GitHub runner .runner JSON
        /// The platform constant.
        let platform: String?
        /// The platformArchitecture constant.
        let platformArchitecture: String?
        /// The agentVersion constant.
        let agentVersion: String?
        /// The ephemeral constant.
        let ephemeral: Bool?
    }

    // MARK: - Filesystem path constants
    /// The findBinary constant.
    private static let findBinary    = "/usr/bin/find"
    /// Full path to the launchctl binary.
    private static let launchctlBinary = "/bin/launchctl"
    /// Base URL used to construct GitHub repository and organisation URLs from plist labels.
    private static let gitHubBaseURL = GitHubConstants.base

    // MARK: - Public API

    /// Performs the full 3-source scan and returns deduplicated `RunnerModel` results.
    /// Synchronous and blocking — always invoke from a background thread.
    func scan() -> [RunnerModel] {
        var models: [String: RunnerModel] = [:]

        // Source 1: extract WorkingDirectory paths and plist-derived gitHubUrl fallbacks.
        let (launchAgentModels, launchAgentPaths) = scanLaunchAgents()

        // Build a name → fallback-URL map from Source 1 so Source 2 can use it.
        let plistFallbackURLs: [String: String] = launchAgentModels.reduce(into: [:]) { dict, m in
            if let url = m.gitHubUrl { dict[m.runnerName] = url }
        }

        // Source 2: .runner JSON is authoritative — provides correct gitHubUrl when present.
        // If gitHubUrl is nil/empty in the JSON, patch it from the plist-derived fallback.
        for var model in scanRunnerJSONFiles(extraRoots: launchAgentPaths) {
            if (model.gitHubUrl ?? "").isEmpty, let fallback = plistFallbackURLs[model.runnerName] {
                model.gitHubUrl = fallback
                log("LocalRunnerScanner › patched gitHubUrl from plist label for \(model.runnerName): \(fallback)")
            }
            models[model.id] = model
        }

        // Collect the set of runnerNames already covered by JSON models.
        // LaunchAgent stubs are only added when NO JSON model shares the same
        // runnerName — prevents duplicates when the same runner name appears
        // in both a plist filename and a .runner JSON file.
        let jsonRunnerNames = Set(models.values.map { $0.runnerName })
        for model in launchAgentModels {
            guard !jsonRunnerNames.contains(model.runnerName) else { continue }
            if models[model.runnerName] == nil { models[model.runnerName] = model }
        }

        // Source 3: mark which runners are currently live.
        let liveLabels = scanLiveServices()
        for key in models.keys {
            if let model = models[key] {
                models[key]?.isRunning = liveLabels.contains { $0.contains(model.runnerName) }
            }
        }
        return models.values.sorted { $0.runnerName < $1.runnerName }
    }

    // MARK: - Source 1: LaunchAgents

    /// Performs the scanLaunchAgents operation.
    private func scanLaunchAgents() -> (models: [RunnerModel], installPaths: Set<String>) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return ([], []) }
        var models: [RunnerModel] = []
        var installPaths = Set<String>()
        let prefix = "actions.runner."
        for url in entries {
            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix(prefix) else { continue }
            // Label format: actions.runner.<owner>.<repo>.<runnerName>
            // parts[0] = owner, parts[1] = repo, parts[2...] = runner name components
            let remainder = String(filename.dropFirst(prefix.count))
            let parts = remainder.components(separatedBy: ".")
            let runnerName = parts.last ?? "runner"
            // Derive a GitHub URL fallback from the label when possible.
            // Requires at least owner + repo (i.e. ≥2 dot-separated parts before the name).
            var plistGitHubUrl: String?
            if parts.count >= 3 {
                let owner = parts[0]
                let repo = parts[1]
                if !owner.isEmpty && !repo.isEmpty {
                    plistGitHubUrl = "\(Self.gitHubBaseURL)/\(owner)/\(repo)"
                }
            } else if parts.count == 2 {
                // Org-scoped runner: actions.runner.<org>.<runnerName>
                let org = parts[0]
                if !org.isEmpty { plistGitHubUrl = "\(Self.gitHubBaseURL)/\(org)" }
            }
            if let plist = NSDictionary(contentsOf: url),
               let workDir = plist["WorkingDirectory"] as? String,
               !workDir.isEmpty {
                installPaths.insert(workDir)
            }
            models.append(RunnerModel(
                runnerName: runnerName,
                gitHubUrl: plistGitHubUrl,
                agentId: nil,
                workFolder: nil,
                installPath: nil,
                isRunning: false
            ))
        }
        return (models, installPaths)
    }

    // MARK: - Source 2: .runner JSON files

    /// Performs the scanRunnerJSONFiles operation.
    private func scanRunnerJSONFiles(extraRoots: Set<String>) -> [RunnerModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var rawPaths = [
            "\(home)/actions-runner",
            "\(home)/runner",
            "\(home)/github-runner",
            "/opt/actions-runner",
            "/opt/runner",
            "/usr/local/actions-runner",
            "/usr/local/runner"
        ]
        for extra in extraRoots where !rawPaths.contains(extra) { rawPaths.append(extra) }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: Self.findBinary)
        task.arguments = rawPaths + ["-maxdepth", "6", "-name", ".runner"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        nonisolated(unsafe) var outputData = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outputData.append(chunk); lock.unlock()
        }
        do { try task.run() } catch {
            log("LocalRunnerScanner › find launch error: \(error)")
            pipe.fileHandleForReading.readabilityHandler = nil
            return []
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
        let raw = String(data: outputData, encoding: .utf8) ?? ""
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { path -> RunnerModel? in
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONDecoder().decode(RunnerJSON.self, from: data)
                else { return nil }
                let name = json.runnerName ?? url.deletingLastPathComponent().lastPathComponent
                return RunnerModel(
                    runnerName: name,
                    gitHubUrl: json.gitHubUrl,
                    agentId: json.agentId,
                    workFolder: json.workFolder,
                    installPath: url.deletingLastPathComponent().path,
                    isRunning: false,
                    platform: json.platform,
                    platformArchitecture: json.platformArchitecture,
                    agentVersion: json.agentVersion,
                    isEphemeral: json.ephemeral ?? false
                )
            }
    }

    // MARK: - Source 3: Live service check

    /// Returns the set of active launchd service labels that contain `actions.runner`.
    ///
    /// Runs `launchctl list` directly via `ProcessRunner` (no shell wrapper), then
    /// filters matching lines in-process — avoids `/bin/zsh -c` overhead and the
    /// shell-injection risk of piping through `grep`.
    private func scanLiveServices() -> Set<String> {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: Self.launchctlBinary),
            arguments: ["list"],
            timeout: 5
        )
        let output = result.output
        guard !output.isEmpty else { return [] }
        var labels = Set<String>()
        for line in output.components(separatedBy: "\n") where line.contains("actions.runner") {
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 3 else { continue }
            let pid = columns[0].trimmingCharacters(in: .whitespaces)
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            if pid != "-", !label.isEmpty { labels.insert(label) }
        }
        return labels
    }
}
