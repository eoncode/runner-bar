import Foundation

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
    // MARK: - LocalRunnerScanner

    // MARK: - .runner JSON schema

    /// Decodable mirror of the relevant fields inside a `.runner` JSON file.
    private struct RunnerJSON: Decodable {
        let gitHubUrl: String?
        let runnerName: String?
        let agentId: Int?
        let workFolder: String?
        let poolName: String?
    }

    // MARK: - Public API

    /// Performs the full 3-source scan and returns deduplicated `RunnerModel` results.
    /// This is a synchronous, blocking call — always invoke from a background thread.
    func scan() -> [RunnerModel] {
        let launchAgentRunners = scanLaunchAgents()
        let jsonRunners = scanRunnerJsonFiles()
        let liveServices = liveLaunchdServices()
        var seen = Set<String>()
        var results: [RunnerModel] = []
        for runner in (launchAgentRunners + jsonRunners) {
            let key = "\(runner.owner)/\(runner.repo)/\(runner.name)"
            guard seen.insert(key).inserted else { continue }
            let isLive = liveServices.contains { svc in
                svc.contains(runner.owner) && svc.contains(runner.repo)
            }
            results.append(RunnerModel(
                id: runner.id,
                name: runner.name,
                owner: runner.owner,
                repo: runner.repo,
                status: isLive ? .online : .offline,
                busy: runner.busy,
                os: runner.os,
                labels: runner.labels,
                isLocal: true
            ))
        }
        return results
    }

    // MARK: - Source 1: LaunchAgents

    private func scanLaunchAgents() -> [RunnerModel] {
        let launchAgentsURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let plists = try? FileManager.default.contentsOfDirectory(
            at: launchAgentsURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return plists
            .filter { $0.lastPathComponent.hasPrefix("actions.runner.") && $0.pathExtension == "plist" }
            .compactMap { plistURL -> RunnerModel? in
                // actions.runner.<owner>.<repo>.<runnerName>.plist
                let parts = plistURL.deletingPathExtension().lastPathComponent
                    .components(separatedBy: ".")
                guard parts.count >= 4 else { return nil }
                let owner = parts[2]
                let repo = parts[3]
                let runnerName = parts.count > 4 ? parts[4...].joined(separator: ".") : "unknown"
                return makeRunnerModel(owner: owner, repo: repo, name: runnerName)
            }
    }

    // MARK: - Source 2: .runner JSON files

    /// Searches known runner install locations only — avoids scanning `~` wholesale
    /// which would trigger macOS TCC prompts for Desktop/Documents/Downloads (macOS 14+).
    private func scanRunnerJsonFiles() -> [RunnerModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchRoots = [
            "\(home)/actions-runner",
            "\(home)/runner",
            "\(home)/github-runner",
            "/opt/actions-runner",
            "/opt/runner",
            "/usr/local/actions-runner",
            "/usr/local/runner"
        ]
        var results: [RunnerModel] = []
        for root in searchRoots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            results += findRunnerJsonFiles(in: root, maxDepth: 6)
                .compactMap { parseRunnerJson(at: $0) }
        }
        return results
    }

    private func findRunnerJsonFiles(in directory: String, maxDepth: Int) -> [String] {
        guard maxDepth > 0 else { return [] }
        var files: [String] = []
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        for item in contents {
            let path = (directory as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if isDir.boolValue {
                files += findRunnerJsonFiles(in: path, maxDepth: maxDepth - 1)
            } else if item == ".runner" {
                files.append(path)
            }
        }
        return files
    }

    private func parseRunnerJson(at path: String) -> RunnerModel? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONDecoder().decode(RunnerJSON.self, from: data),
              let urlStr = json.gitHubUrl,
              let url = URL(string: urlStr)
        else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else { return nil }
        let owner = pathComponents[0]
        let repo = pathComponents[1]
        let name = json.runnerName ?? "unknown"
        return makeRunnerModel(owner: owner, repo: repo, name: name)
    }

    // MARK: - Source 3: Live service check

    private func liveLaunchdServices() -> [String] {
        let output = shell("launchctl list | grep actions.runner", timeout: 5)
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - Factory

    private func makeRunnerModel(owner: String, repo: String, name: String) -> RunnerModel {
        RunnerModel(
            id: abs((owner + repo + name).hashValue),
            name: name,
            owner: owner,
            repo: repo,
            status: .offline,
            busy: false,
            os: "macOS",
            labels: [],
            isLocal: true
        )
    }
}
