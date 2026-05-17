import Foundation

// MARK: - LocalRunnerScanner

/// Discovers locally-installed GitHub Actions self-hosted runners without
/// requiring a GitHub API token. Uses three complementary scan sources:
///
/// 1. **LaunchAgents** — `~/Library/LaunchAgents/actions.runner.*.plist`
///    Parses `owner`, `repo`, and `runnerName` from the plist filename.
///    Also reads the `WorkingDirectory` key from the plist XML so the
///    runner's install path is known even for non-standard locations.
///    This file lives in `~/Library` and survives app reinstalls.
///
/// 2. **`.runner` JSON files** — searches the known default install paths
///    PLUS any install paths extracted from LaunchAgent plists (Source 1).
///    This means any runner registered as a service is always found,
///    regardless of where it was installed — no UserDefaults or any other
///    app-level persistence required.
///    Default search roots: `~/actions-runner`, `~/runner`, `~/github-runner`,
///    `/opt/actions-runner`, `/opt/runner`, `/usr/local/actions-runner`,
///    `/usr/local/runner` up to depth 6.
///
/// 3. **Live service check** — `launchctl list | grep actions.runner`
///    Flags which runners currently have an active launchd service.
struct LocalRunnerScanner {
    // MARK: - .runner JSON schema

    private struct RunnerJSON: Decodable {
        let gitHubUrl: String?
        let runnerName: String?
        let agentId: Int?
        let workFolder: String?
    }

    // MARK: - Public API

    /// Performs the full 3-source scan and returns deduplicated `RunnerModel` results.
    /// Synchronous and blocking — always invoke from a background thread.
    func scan() -> [RunnerModel] {
        var models: [String: RunnerModel] = [:]

        // Source 1: LaunchAgents — extract install paths from WorkingDirectory key.
        let (launchAgentModels, launchAgentPaths) = scanLaunchAgents()

        // Source 2: .runner JSON — most authoritative (richer data).
        // Seed with install paths extracted from LaunchAgent plists so runners
        // in non-standard locations are always found without any persisted config.
        for model in scanRunnerJSONFiles(extraRoots: launchAgentPaths) {
            models[model.id] = model
        }

        // Merge LaunchAgent entries that weren't covered by a .runner JSON file.
        for model in launchAgentModels {
            let compositeKey = "\(model.runnerName)-\(model.gitHubUrl ?? "")"
            let coveredByJSON = models.values.contains { existing in
                "\(existing.runnerName)-\(existing.gitHubUrl ?? "")" == compositeKey
            }
            guard !coveredByJSON else { continue }
            if models[compositeKey] == nil {
                models[compositeKey] = model
            }
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

    /// Scans `~/Library/LaunchAgents/actions.runner.*.plist`.
    /// Returns both the parsed `RunnerModel` array and the set of
    /// `WorkingDirectory` paths found in those plists.
    /// The working directory paths are passed to `scanRunnerJSONFiles` so
    /// runners installed outside the default search roots are always found.
    private func scanLaunchAgents() -> (models: [RunnerModel], installPaths: Set<String>) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return ([], []) }

        var models: [RunnerModel] = []
        var installPaths = Set<String>()
        let prefix = "actions.runner."

        for url in entries {
            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix(prefix) else { continue }
            let remainder = String(filename.dropFirst(prefix.count))
            let parts = remainder.components(separatedBy: ".")
            guard parts.count >= 2 else { continue }
            let owner = parts[0]
            let repo = parts[1]
            let runnerName = parts.count > 2 ? parts[2...].joined(separator: ".") : "runner"
            let gitHubUrl = "https://github.com/\(owner)/\(repo)"

            // Read WorkingDirectory from the plist — this is the runner install dir.
            // The runner writes this key itself during `svc.sh install`, so it
            // reliably reflects the actual install location even for custom paths.
            if let plist = NSDictionary(contentsOf: url),
               let workDir = plist["WorkingDirectory"] as? String,
               !workDir.isEmpty {
                installPaths.insert(workDir)
            }

            models.append(RunnerModel(
                runnerName: runnerName,
                gitHubUrl: gitHubUrl,
                agentId: nil,
                workFolder: nil,
                installPath: nil,
                isRunning: false
            ))
        }
        return (models, installPaths)
    }

    // MARK: - Source 2: .runner JSON files

    /// Searches known default runner install locations plus any `extraRoots`
    /// (typically `WorkingDirectory` values from LaunchAgent plists).
    /// Avoids scanning `~` wholesale to prevent macOS TCC prompts (macOS 14+).
    private func scanRunnerJSONFiles(extraRoots: Set<String>) -> [RunnerModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var rawPaths = [
            "\(home)/actions-runner",
            "\(home)/runner",
            "\(home)/github-runner",
            "/opt/actions-runner",
            "/opt/runner",
            "/usr/local/actions-runner",
            "/usr/local/runner",
        ]
        // Append LaunchAgent WorkingDirectory paths, deduplicating.
        // These are the actual install directories written by svc.sh install,
        // so they cover any non-standard location without any extra config.
        for extra in extraRoots where !rawPaths.contains(extra) {
            rawPaths.append(extra)
        }

        let searchPaths = rawPaths.map { "'\($0)'" }.joined(separator: " ")
        let raw = shell(
            "find \(searchPaths) -maxdepth 6 -name '.runner' 2>/dev/null",
            timeout: 15
        )
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
                    isRunning: false
                )
            }
    }

    // MARK: - Source 3: Live service check

    private func scanLiveServices() -> Set<String> {
        let output = shell(
            "launchctl list 2>/dev/null | grep actions.runner",
            timeout: 5
        )
        guard !output.isEmpty else { return [] }

        var labels = Set<String>()
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 3 else { continue }
            let pid = columns[0].trimmingCharacters(in: .whitespaces)
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            if pid != "-", !label.isEmpty {
                labels.insert(label)
            }
        }
        return labels
    }
}
