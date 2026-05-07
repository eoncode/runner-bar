import Foundation

// MARK: - LocalRunnerScanner

/// Discovers locally-installed GitHub Actions self-hosted runners without
/// requiring a GitHub API token. Uses three complementary scan sources:
///
/// 1. **LaunchAgents** — `~/Library/LaunchAgents/actions.runner.*.plist`
///    Parses `owner`, `repo`, and `runnerName` from the plist filename.
///
/// 2. **`.runner` JSON files** — `find ~ /opt /usr/local -name ".runner" -maxdepth 6`
///    Reads `gitHubUrl`, `runnerName`, `agentId`, and `workFolder` from each
///    file. This is the most authoritative local source.
///
/// 3. **Live process check** — `ps aux | grep Runner.Listener`
///    Flags which runners currently have an active `Runner.Listener` process,
///    indicating they are actively polling for jobs.
///
/// Results from all three sources are merged and deduplicated by `agentId`
/// (preferred) or the `runnerName + gitHubUrl` composite key.
struct LocalRunnerScanner {
    // MARK: - .runner JSON schema

    /// Decodable mirror of the relevant fields inside a `.runner` JSON file.
    private struct RunnerJSON: Decodable {
        let gitHubUrl: String?
        let runnerName: String?
        let agentId: Int?
        let workFolder: String?
    }

    // MARK: - Public API

    /// Performs the full 3-source scan and returns deduplicated `RunnerModel` results.
    /// This is a synchronous, blocking call — always invoke from a background thread.
    func scan() -> [RunnerModel] {
        var models: [String: RunnerModel] = [:]   // keyed by stable id

        // Source 2 first: .runner JSON is most authoritative — richer data
        for model in scanRunnerJSONFiles() {
            models[model.id] = model
        }

        // Source 1: LaunchAgents — fills in runners whose .runner file wasn't found
        for model in scanLaunchAgents() where models[model.id] == nil {
            models[model.id] = model
        }

        // Source 3: mark which runners are live
        let livePaths = scanLiveProcesses()
        for key in models.keys {
            // Safe optional binding — key is guaranteed to exist but avoids force-unwrap.
            if let model = models[key] {
                if let path = model.installPath {
                    // Normalize path by removing trailing slashes for comparison
                    let normalizedPath = URL(fileURLWithPath: path).path
                    models[key]?.isRunning = livePaths.contains(normalizedPath)
                } else {
                    // If no install path is known, we cannot reliably determine
                    // liveness via process-path correlation.
                    models[key]?.isRunning = false
                }
            }
        }

        return models.values.sorted { $0.runnerName < $1.runnerName }
    }

    // MARK: - Source 1: LaunchAgents

    /// Scans `~/Library/LaunchAgents` for plist files matching the pattern
    /// `actions.runner.<owner>.<repo>.<runnerName>.plist` and returns a
    /// `RunnerModel` for each one found.
    ///
    /// Attempts to read the `WorkingDirectory` from the plist to accurately
    /// set the `installPath`, which is used for liveness correlation and
    /// to load authoritative `.runner` JSON data if available.
    private func scanLaunchAgents() -> [RunnerModel] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return [] }

        let prefix = "actions.runner."
        return entries.compactMap { url -> RunnerModel? in
            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix(prefix) else { return nil }

            // 1. Load the plist to find the installation directory.
            let plist = NSDictionary(contentsOf: url)
            let workingDir = plist?["WorkingDirectory"] as? String

            // 2. If we found a working directory, try to load authoritative JSON data.
            if let workingDir = workingDir {
                let jsonPath = URL(fileURLWithPath: workingDir).appendingPathComponent(".runner").path
                if let model = decodeRunnerJSON(at: jsonPath) {
                    return model
                }
            }

            // 3. Fallback: Parse filename if JSON is missing or WorkingDirectory is unknown.
            let remainder = String(filename.dropFirst(prefix.count))
            let parts = remainder.components(separatedBy: ".")
            guard parts.count >= 2 else { return nil }
            let owner = parts[0]
            let repo = parts[1]
            let runnerName = parts.count > 2 ? parts[2...].joined(separator: ".") : "runner"
            let gitHubUrl = "https://github.com/\(owner)/\(repo)"

            return RunnerModel(
                runnerName: runnerName,
                gitHubUrl: gitHubUrl,
                agentId: nil,
                workFolder: nil,
                installPath: workingDir,
                isRunning: false
            )
        }
    }

    // MARK: - Source 2: .runner JSON files

    /// Uses `find` to locate `.runner` JSON files in common install locations
    /// and decodes each one into a `RunnerModel`.
    private func scanRunnerJSONFiles() -> [RunnerModel] {
        // Limit search depth to 6 to avoid traversing deep node_modules etc.
        // shell() is defined in Shell.swift.
        let raw = shell(
            "find ~ /opt /usr/local -maxdepth 6 -name '.runner' 2>/dev/null",
            timeout: 15
        )
        guard !raw.isEmpty else { return [] }

        return raw.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { decodeRunnerJSON(at: $0) }
    }

    /// Helper to decode a `.runner` JSON file into a `RunnerModel`.
    private func decodeRunnerJSON(at path: String) -> RunnerModel? {
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
            isRunning: false
        )
    }

    // MARK: - Source 3: Live process check

    /// Returns a set of absolute installation directories where a `Runner.Listener`
    /// process is currently active.
    ///
    /// The runner name does not appear in `ps` arguments, so we correlate liveness
    /// by the directory containing the `Runner.Listener` executable.
    private func scanLiveProcesses() -> Set<String> {
        // Use -e (all processes) and -o command (only the command and arguments).
        // -ww ensures the output is not truncated.
        // shell() is defined in Shell.swift.
        let output = shell("ps -e -ww -o command | grep Runner.Listener | grep -v grep", timeout: 5)
        guard !output.isEmpty else { return [] }

        var livePaths = Set<String>()
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            // Typical line: /Users/name/actions-runner/bin/Runner.Listener run --startuptype service
            // We want the parent of the 'bin' directory (or the directory itself if bin is missing).
            let parts = line.components(separatedBy: " ")
            guard let execPath = parts.first else { continue }
            let url = URL(fileURLWithPath: execPath)

            // Standard layout: <installPath>/bin/Runner.Listener
            // Some layouts might have Runner.Listener in the root.
            var installDir = url.deletingLastPathComponent()
            if installDir.lastPathComponent == "bin" {
                installDir = installDir.deletingLastPathComponent()
            }
            livePaths.insert(installDir.path)
        }
        return livePaths
    }
}
