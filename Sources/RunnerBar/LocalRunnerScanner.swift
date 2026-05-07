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
        let liveNames = scanLiveProcesses()
        for key in models.keys {
            models[key]?.isRunning = liveNames.contains(models[key]!.runnerName)
        }

        return models.values.sorted { $0.runnerName < $1.runnerName }
    }

    // MARK: - Source 1: LaunchAgents

    /// Scans `~/Library/LaunchAgents` for plist files matching the pattern
    /// `actions.runner.<owner>.<repo>.<runnerName>.plist` and returns a minimal
    /// `RunnerModel` for each one found.
    private func scanLaunchAgents() -> [RunnerModel] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return [] }

        return entries.compactMap { url -> RunnerModel? in
            let filename = url.deletingPathExtension().lastPathComponent
            // Expected format: actions.runner.<owner>.<repo>.<runnerName>
            let parts = filename.components(separatedBy: ".")
            guard parts.count >= 4, parts[0] == "actions", parts[1] == "runner"
            else { return nil }
            let owner = parts[2]
            let repo = parts[3]
            let runnerName = parts.count > 4 ? parts[4...].joined(separator: ".") : "runner"
            let gitHubUrl = "https://github.com/\(owner)/\(repo)"
            return RunnerModel(
                runnerName: runnerName,
                gitHubUrl: gitHubUrl,
                agentId: nil,
                workFolder: nil,
                installPath: nil,
                isRunning: false
            )
        }
    }

    // MARK: - Source 2: .runner JSON files

    /// Uses `find` to locate `.runner` JSON files in common install locations
    /// and decodes each one into a `RunnerModel`.
    private func scanRunnerJSONFiles() -> [RunnerModel] {
        // Limit search depth to 6 to avoid traversing deep node_modules etc.
        let raw = shell(
            "find ~ /opt /usr/local -name '.runner' -maxdepth 6 2>/dev/null",
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

    // MARK: - Source 3: Live process check

    /// Returns the set of runner names that currently have an active
    /// `Runner.Listener` process, derived from `ps aux` output.
    private func scanLiveProcesses() -> Set<String> {
        let output = shell("ps aux | grep Runner.Listener | grep -v grep", timeout: 5)
        guard !output.isEmpty else { return [] }

        var names = Set<String>()
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            // Extract --runnerName argument from the process command line
            if let range = line.range(of: "--runnerName ") {
                let after = String(line[range.upperBound...])
                let name = after.components(separatedBy: " ").first ?? ""
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }
}
