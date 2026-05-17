import Foundation

// MARK: - LocalRunnerScanner

/// Discovers locally-installed GitHub Actions self-hosted runners without
/// requiring a GitHub API token. Uses three complementary scan sources:
///
/// 1. **LaunchAgents** — `~/Library/LaunchAgents/actions.runner.*.plist`
///    Reads the `WorkingDirectory` key from each plist so the runner's exact
///    install path is known for any custom location. The plist filename is
///    used ONLY to extract the runner name for display — it is never used
///    to construct a `gitHubUrl` (the filename encoding is lossy for org
///    names containing hyphens). `gitHubUrl` is always sourced from the
///    `.runner` JSON file (Source 2) which is authoritative.
///
/// 2. **`.runner` JSON files** — searches the known default install paths
///    PLUS any `WorkingDirectory` paths extracted from LaunchAgent plists.
///    Provides `gitHubUrl`, `runnerName`, `agentId`, and `workFolder`.
///    Default roots: `~/actions-runner`, `~/runner`, `~/github-runner`,
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

        // Source 1: extract WorkingDirectory paths from LaunchAgent plists.
        // Runner name is parsed from the filename for display; gitHubUrl is NOT
        // derived here — the filename encoding is lossy for hyphenated org names.
        let (launchAgentModels, launchAgentPaths) = scanLaunchAgents()

        // Source 2: .runner JSON is authoritative — provides correct gitHubUrl.
        // Seeded with LaunchAgent WorkingDirectory paths so custom-location
        // runners are always found without any app-level persistence.
        for model in scanRunnerJSONFiles(extraRoots: launchAgentPaths) {
            models[model.id] = model
        }

        // Merge LaunchAgent-only entries (runners with no .runner JSON found).
        // These have gitHubUrl = nil so the enricher will skip API calls for them,
        // preventing bogus 404s from malformed filename-derived scopes.
        for model in launchAgentModels {
            let compositeKey = model.runnerName
            let coveredByJSON = models.values.contains { $0.runnerName == model.runnerName }
            guard !coveredByJSON, models[compositeKey] == nil else { continue }
            models[compositeKey] = model
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
    ///
    /// Returns:
    /// - `models`: Runner stubs with `runnerName` parsed from filename and
    ///   `gitHubUrl = nil`. The nil gitHubUrl prevents the enricher from
    ///   constructing a malformed API scope from the lossy filename encoding.
    /// - `installPaths`: `WorkingDirectory` values read from each plist, passed
    ///   to `scanRunnerJSONFiles` as extra search roots.
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
            // Last component is the runner name; earlier components are owner+repo
            // but we intentionally do NOT reconstruct gitHubUrl from them.
            let runnerName = parts.last ?? "runner"

            // Read WorkingDirectory — the runner's actual install path.
            if let plist = NSDictionary(contentsOf: url),
               let workDir = plist["WorkingDirectory"] as? String,
               !workDir.isEmpty {
                installPaths.insert(workDir)
            }

            // gitHubUrl is intentionally nil here. The .runner JSON (Source 2)
            // provides the correct URL once the install dir is searched.
            models.append(RunnerModel(
                runnerName: runnerName,
                gitHubUrl: nil,
                agentId: nil,
                workFolder: nil,
                installPath: nil,
                isRunning: false
            ))
        }
        return (models, installPaths)
    }

    // MARK: - Source 2: .runner JSON files

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
