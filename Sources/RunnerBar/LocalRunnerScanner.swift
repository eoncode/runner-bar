import Foundation

// MARK: - LocalRunnerScanner

/// Discovers locally-installed GitHub Actions self-hosted runners without
/// requiring a GitHub API token. Uses three complementary scan sources:
///
/// 1. **LaunchAgents** — `~/Library/LaunchAgents/actions.runner.*.plist`
///    Parses `owner`, `repo`, and `runnerName` from the plist filename.
///
/// 2. **`.runner` JSON files** — `find ~ /opt /usr/local -maxdepth 6 -name ".runner"`
///    Reads `gitHubUrl`, `runnerName`, `agentId`, and `workFolder` from each
///    file. This is the most authoritative local source.
///
/// 3. **Live process check** — `ps aux | grep Runner.Listener`
///    Flags which runners currently have an active `Runner.Listener` process.
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
        let activeLabels = scanLiveLabels()
        let activePaths = scanLivePaths()

        for key in models.keys {
            if let model = models[key] {
                var isRunning = false
                if let label = model.launchLabel, activeLabels.contains(label) {
                    isRunning = true
                } else if let path = model.installPath, activePaths.contains(path) {
                    isRunning = true
                }
                models[key]?.isRunning = isRunning
            }
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

        let prefix = "actions.runner."
        return entries.compactMap { url -> RunnerModel? in
            let filename = url.deletingPathExtension().lastPathComponent
            // Only process files whose names start with the known prefix.
            guard filename.hasPrefix(prefix) else { return nil }

            // The launchctl label is usually the filename without .plist
            let launchLabel = filename

            // Strip the prefix, leaving "<owner>.<repo>.<runnerName>"
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
                installPath: nil,
                launchLabel: launchLabel,
                isRunning: false
            )
        }
    }

    // MARK: - Source 2: .runner JSON files

    /// Uses `find` to locate `.runner` JSON files in common install locations
    /// and decodes each one into a `RunnerModel`.
    private func scanRunnerJSONFiles() -> [RunnerModel] {
        // Correct find order: paths then options then predicates.
        // shell() is defined in Shell.swift.
        let raw = shell(
            "find ~ /opt /usr/local -maxdepth 6 -name '.runner' 2>/dev/null",
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

                let installPath = url.deletingLastPathComponent().path
                let name = json.runnerName ?? url.deletingLastPathComponent().lastPathComponent

                return RunnerModel(
                    runnerName: name,
                    gitHubUrl: json.gitHubUrl,
                    agentId: json.agentId,
                    workFolder: json.workFolder,
                    installPath: installPath,
                    isRunning: false
                )
            }
    }

    // MARK: - Source 3: Liveness

    /// Returns the set of active launchd labels starting with "actions.runner."
    private func scanLiveLabels() -> Set<String> {
        let output = shell("launchctl list | grep actions.runner", timeout: 5)
        var labels = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 {
                let label = parts[2].trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { labels.insert(label) }
            }
        }
        return labels
    }

    /// Returns the set of current working directories for all `Runner.Listener` processes.
    private func scanLivePaths() -> Set<String> {
        // Use lsof to find CWDs of all Runner.Listener processes in one go.
        // -c: command name, -a: AND filters, -d cwd: current working directory, -Fn: output name only prefixed with 'n'
        let output = shell("lsof -c Runner.Listener -a -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//'", timeout: 5)
        let paths = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(paths)
    }
}
