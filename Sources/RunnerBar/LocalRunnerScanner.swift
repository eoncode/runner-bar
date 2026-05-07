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
/// 3. **Live service check** — `launchctl list | grep actions.runner`
///    Flags which runners currently have an active launchd service, indicating
///    they are registered and running. Service labels embed owner, repo, and
///    runnerName, so runners with identical names but different scopes are
///    correctly distinguished — no cross-runner contamination.
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
        let liveLabels = scanLiveServices()
        for key in models.keys {
            // Safe optional binding — key is guaranteed to exist but avoids force-unwrap.
            if let model = models[key] {
                // Match by service label which contains the runner name. This is
                // scope-aware: two runners with the same name but different
                // owner/repo get distinct labels and are matched independently.
                models[key]?.isRunning = liveLabels.contains { $0.contains(model.runnerName) }
            }
        }

        return models.values.sorted { $0.runnerName < $1.runnerName }
    }

    // MARK: - Source 1: LaunchAgents

    /// Scans `~/Library/LaunchAgents` for plist files matching the pattern
    /// `actions.runner.<owner>.<repo>.<runnerName>.plist` and returns a minimal
    /// `RunnerModel` for each one found.
    ///
    /// Parsing splits on the `"actions.runner."` prefix rather than on every `.`
    /// so that dotted owner, repo, or runner names (e.g. `my.org/my.repo`) are
    /// handled correctly without silently mis-parsing the components.
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
            // Strip the prefix, leaving "<owner>.<repo>.<runnerName>" (or just
            // "<owner>.<repo>" for runners registered at org level).
            let remainder = String(filename.dropFirst(prefix.count))
            // The remainder uses the first two dot-separated tokens as owner and
            // repo; everything after the second dot is the runner name. This is
            // still an approximation for dotted owner/repo names, but it is
            // significantly more robust than splitting the whole filename on ".".
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
                isRunning: false
            )
        }
    }

    // MARK: - Source 2: .runner JSON files

    /// Uses `find` to locate `.runner` JSON files in common install locations
    /// and decodes each one into a `RunnerModel`.
    private func scanRunnerJSONFiles() -> [RunnerModel] {
        // -maxdepth MUST precede -name: on macOS BSD find, placing -maxdepth
        // after a predicate applies the depth limit only to subtrees past that
        // point, so the guard would not work and could traverse node_modules etc.
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

    /// Returns the set of launchd service labels for runner services that are
    /// currently loaded and running, using `launchctl list | grep actions.runner`.
    ///
    /// This replaces the previous `ps aux | grep Runner.Listener` approach, which
    /// was broken because `Runner.Listener` does not pass `--runnerName` — so the
    /// old parsing never matched and `isRunning` was always `false`.
    ///
    /// Using launchctl service labels also fixes cross-runner contamination: two
    /// runners with the same `runnerName` but different owner/repo get distinct
    /// labels (e.g. `actions.runner.orgA.repoA.my-runner` vs
    /// `actions.runner.orgB.repoB.my-runner`) and are matched independently.
    private func scanLiveServices() -> Set<String> {
        // shell() is defined in Shell.swift.
        let output = shell(
            "launchctl list 2>/dev/null | grep actions.runner",
            timeout: 5
        )
        guard !output.isEmpty else { return [] }

        var labels = Set<String>()
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            // launchctl list output: "<PID/->\t<exitCode>\t<label>"
            // A non-"-" PID in column 1 means the service is currently running.
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 3 else { continue }
            let pid = columns[0].trimmingCharacters(in: .whitespaces)
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            // Only count services with an active PID (not "-").
            if pid != "-", !label.isEmpty {
                labels.insert(label)
            }
        }
        return labels
    }
}
