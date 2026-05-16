import Foundation

// MARK: - LocalRunnerScanner

/// Discovers locally-installed GitHub Actions self-hosted runners without
/// requiring a GitHub API token. Uses three complementary scan sources:
///
/// 1. **LaunchAgents** (`~/Library/LaunchAgents/actions.runner.*`)
///    Reads the plist filename to derive owner, repo, and runner name.
///    Avoids broad filesystem scans that would trigger macOS TCC prompts.
///
/// 2. **Runner JSON files** (`.runner` in known install dirs)
///    Parses the JSON config written by the runner install script for richer
///    metadata (agentId, gitHubUrl, OS).
///
/// 3. **Live launchd services** (`launchctl list`)
///    Flags which runners currently have an active launchd service, indicating
///    they are registered and running.
struct LocalRunnerScanner {

    // MARK: - .runner JSON schema

    /// Decodable mirror of the relevant fields inside a `.runner` JSON file.
    private struct RunnerJSON: Decodable {
        let runnerName: String?
        let gitHubUrl: String?
        let agentId: Int?
        let osName: String?

        enum CodingKeys: String, CodingKey {
            case runnerName
            case gitHubUrl
            case agentId
            case osName = "os"
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    /// Performs the full 3-source scan and returns deduplicated `RunnerModel` results.
    /// This is a synchronous, blocking call — always invoke from a background thread.
    func scan() -> [RunnerModel] {
        var models: [String: RunnerModel] = [:]
        for model in scanRunnerJSONFiles() { models[model.id] = model }
        for model in scanLaunchAgents() {
            let compositeKey = "\(model.runnerName)-\(model.gitHubUrl ?? "")"
            let alreadyCoveredByJSON = models.values.contains { existing in
                existing.runnerName == model.runnerName && existing.gitHubUrl == model.gitHubUrl
            }
            if !alreadyCoveredByJSON { models[compositeKey] = model }
        }
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
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let prefix = "actions.runner."
        return entries.compactMap { url -> RunnerModel? in
            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix(prefix) else { return nil }
            let parts = filename.dropFirst(prefix.count).components(separatedBy: ".")
            guard parts.count >= 2 else { return nil }
            let owner = parts[0]
            let repo = parts[1]
            let runnerName = parts.count > 2 ? parts[2...].joined(separator: ".") : "runner"
            // NOSONAR — user-facing GitHub repo URL, not a configurable service endpoint.
            let gitHubUrl = "https://github.com/\(owner)/\(repo)"
            return RunnerModel.make(
                runnerName: runnerName,
                gitHubUrl: gitHubUrl,
                agentId: nil,
                os: nil,
                isRunning: false
            )
        }
    }

    // MARK: - Source 2: Runner JSON files

    /// Scans well-known runner install directories for `.runner` JSON config files.
    /// Explicit paths only — avoids broad scans
    /// which would trigger macOS TCC prompts for Desktop/Documents/Downloads (macOS 14+).
    private func scanRunnerJSONFiles() -> [RunnerModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
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
                let data: Data
                do { data = try Data(contentsOf: url) } catch {
                    log("LocalRunnerScanner › failed to read \(path): \(error)")
                    return nil
                }
                let json: RunnerJSON
                do { json = try JSONDecoder().decode(RunnerJSON.self, from: data) } catch {
                    log("LocalRunnerScanner › failed to decode \(path): \(error)")
                    return nil
                }
                let name = json.runnerName ?? url.deletingLastPathComponent().lastPathComponent
                return RunnerModel.make(
                    runnerName: name,
                    gitHubUrl: json.gitHubUrl,
                    agentId: json.agentId,
                    os: json.osName,
                    isRunning: false
                )
            }
    }

    // MARK: - Source 3: Live launchd services

    private func scanLiveServices() -> [String] {
        let output = shell(
            "launchctl list 2>/dev/null | grep actions.runner",
            timeout: 5
        )
        guard !output.isEmpty else { return [] }
        var labels = Set<String>()
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let columns = line.components(separatedBy: "\t")
            if columns.count >= 3 { labels.insert(columns[2]) }
        }
        return Array(labels)
    }
}
