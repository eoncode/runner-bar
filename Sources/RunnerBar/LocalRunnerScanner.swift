import Foundation

// MARK: - LocalRunnerScanner

/// Discovers locally-installed GitHub Actions self-hosted runners without
/// requiring a GitHub API token. Uses three complementary scan sources:
///
/// 1. **LaunchAgents** — `~/Library/LaunchAgents/actions.runner.*.plist`
///    Parses `owner`, `repo`, and `runnerName` from the plist filename.
///
/// 2. **`.runner` JSON files** — searches known runner install paths only
///    (NOT `~` wholesale, which triggers macOS TCC permission dialogs for
///    Desktop/Documents/Downloads). Searches:
///    `~/actions-runner`, `~/runner`, `~/github-runner`, `/opt/actions-runner`,
///    `/opt/runner`, `/usr/local/actions-runner`, `/usr/local/runner`
///    up to depth 6. This avoids the TCC prompt while still covering all
///    common self-hosted runner install locations.
///
/// 3. **Live service check** — `launchctl list | grep actions.runner`
///    Flags which runners currently have an active launchd service, indicating
///    they are registered and running.
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
        var models: [String: RunnerModel] = [:]

        // Source 2 first: .runner JSON is most authoritative — richer data.
        for model in scanRunnerJSONFiles() {
            models[model.id] = model
        }

        // Source 1: LaunchAgents — fills in runners whose .runner file wasn't found.
        for model in scanLaunchAgents() {
            let compositeKey = "\(model.runnerName)-\(model.gitHubUrl ?? "")"
            let alreadyCoveredByJSON = models.values.contains { existing in
                let existingComposite = "\(existing.runnerName)-\(existing.gitHubUrl ?? "")"
                return existingComposite == compositeKey
            }
            guard !alreadyCoveredByJSON else { continue }
            if models[compositeKey] == nil {
                models[compositeKey] = model
            }
        }

        // Source 3: mark which runners are live.
        let liveLabels = scanLiveServices()
        for key in models.keys {
            if let model = models[key] {
                models[key]?.isRunning = liveLabels.contains { $0.contains(model.runnerName) }
            }
        }

        return models.values.sorted { $0.runnerName < $1.runnerName }
    }

    // MARK: - Source 1: LaunchAgents

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
                isRunning: false
            )
        }
    }

    // MARK: - Source 2: .runner JSON files

    /// Searches known runner install locations only — avoids scanning `~` wholesale
    /// which would trigger macOS TCC prompts for Desktop/Documents/Downloads (macOS 14+).
    private func scanRunnerJSONFiles() -> [RunnerModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Known self-hosted runner install directories — explicit paths only.
        // ⚠️ DO NOT add `~` or `$HOME` here: broad home-dir scans trigger TCC dialogs.
        // ⚠️ Each path is single-quoted before shell interpolation so that home
        // directories containing spaces (e.g. /Users/First Last) don't break find.
        let rawPaths = [
            "\(home)/actions-runner",
            "\(home)/runner",
            "\(home)/github-runner",
            "/opt/actions-runner",
            "/opt/runner",
            "/usr/local/actions-runner",
            "/usr/local/runner",
        ]
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
