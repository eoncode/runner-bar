import Foundation

/// Scans the local machine for GitHub Actions self-hosted runners using three sources:
/// 1. LaunchAgents: ~/Library/LaunchAgents/actions.runner.*.plist
/// 2. .runner JSON files: find ~ /opt /usr/local -name ".runner" -maxdepth 6
/// 3. Live process check: ps aux | grep Runner.Listener
///
/// Deduplicates by agentId or runnerName + gitHubUrl combo.
struct LocalRunnerScanner {

    /// Represents a locally discovered runner with full metadata.
    struct LocalRunnerInfo {
        let name: String
        let gitHubUrl: String
        let agentId: Int?
        let installPath: String?
        let isRunning: Bool

        /// Converts to a RunnerModel for display in SettingsView.
        func toRunner() -> Runner {
            // Create a Runner with local info; status derived from isRunning
            var runner = Runner(
                id: agentId ?? 0,
                name: name,
                status: isRunning ? "online" : "offline",
                busy: false, // Will be enriched later via API if token available
                metrics: nil
            )
            runner.installPath = installPath
            runner.gitHubUrl = gitHubUrl
            runner.isLocal = true
            return runner
        }
    }

    /// Performs the 3-source local scan and returns deduplicated runner info.
    static func scan() -> [LocalRunnerInfo] {
        var runners: [LocalRunnerInfo] = []
        var seenKeys: Set<String> = []

        // Source 1: LaunchAgents
        let launchAgentRunners = scanLaunchAgents()
        for runner in launchAgentRunners {
            let key = makeDedupKey(runner)
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                runners.append(runner)
            }
        }

        // Source 2: .runner JSON files
        let jsonRunners = scanRunnerJsonFiles()
        for runner in jsonRunners {
            let key = makeDedupKey(runner)
            if !seenKeys.contains(key) {
                seenKeys.insert(key)
                runners.append(runner)
            }
        }

        // Source 3: Live process check - enrich existing runners with running status
        let runningNames = scanRunningProcesses()
        runners = runners.map { runner in
            let isRunning = runningNames.contains(runner.name) ||
                           runningNames.contains { $0.contains(runner.name) }
            return LocalRunnerInfo(
                name: runner.name,
                gitHubUrl: runner.gitHubUrl,
                agentId: runner.agentId,
                installPath: runner.installPath,
                isRunning: isRunning
            )
        }

        log("LocalRunnerScanner › found \(runners.count) local runner(s)")
        return runners
    }

    // MARK: - Source 1: LaunchAgents

    /// Scans ~/Library/LaunchAgents/actions.runner.*.plist files.
    /// Parses owner, repo, runnerName from filename pattern: actions.runner.{owner}.{repo}.{runnerName}.plist
    private static func scanLaunchAgents() -> [LocalRunnerInfo] {
        var runners: [LocalRunnerInfo] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let launchAgentsDir = "\(homeDir)/Library/LaunchAgents"

        guard let enumerator = FileManager.default.enumerator(atPath: launchAgentsDir) else {
            return runners
        }

        for case let file as String in enumerator {
            guard file.hasPrefix("actions.runner.") && file.hasSuffix(".plist") else { continue }

            // Parse filename: actions.runner.{owner}.{repo}.{runnerName}.plist
            // or actions.runner.{org}.{runnerName}.plist for org-scoped runners
            let nameWithoutExt = file.replacingOccurrences(of: ".plist", with: "")
            let components = nameWithoutExt.components(separatedBy: ".")

            guard components.count >= 4 else { continue }

            let runnerName: String
            let gitHubUrl: String

            if components.count == 4 {
                // Org-scoped: actions.runner.{org}.{runnerName}
                let org = components[2]
                runnerName = components[3]
                gitHubUrl = "https://github.com/\(org)"
            } else {
                // Repo-scoped: actions.runner.{owner}.{repo}.{runnerName}
                let owner = components[2]
                let repo = components[3]
                runnerName = components.count > 4 ? components.suffix(from: 4).joined(separator: ".") : components[4]
                gitHubUrl = "https://github.com/\(owner)/\(repo)"
            }

            let plistPath = "\(launchAgentsDir)/\(file)"
            runners.append(LocalRunnerInfo(
                name: runnerName,
                gitHubUrl: gitHubUrl,
                agentId: nil,
                installPath: plistPath,
                isRunning: false
            ))
        }

        log("LocalRunnerScanner › LaunchAgents: found \(runners.count) runner(s)")
        return runners
    }

    // MARK: - Source 2: .runner JSON files

    /// Scans for .runner JSON files in common installation directories.
    /// Reads gitHubUrl, runnerName, agentId, workFolder from JSON.
    private static func scanRunnerJsonFiles() -> [LocalRunnerInfo] {
        var runners: [LocalRunnerInfo] = []
        let searchPaths = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            "/opt",
            "/usr/local"
        ]

        for basePath in searchPaths {
            let findCommand = "find \"\(basePath)\" -maxdepth 6 -name \".runner\" 2>/dev/null"
            let output = shell(findCommand, timeout: 10)
            let paths = output.components(separatedBy: "\n").filter { !$0.isEmpty }

            for path in paths {
                guard let data = FileManager.default.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let runnerName = json["runnerName"] as? String ?? ""
                let gitHubUrl = json["gitHubUrl"] as? String ?? ""
                let agentId = json["agentId"] as? Int
                let workFolder = json["workFolder"] as? String

                guard !runnerName.isEmpty else { continue }

                runners.append(LocalRunnerInfo(
                    name: runnerName,
                    gitHubUrl: gitHubUrl,
                    agentId: agentId,
                    installPath: path,
                    isRunning: false
                ))

                if let workFolder = workFolder {
                    log("LocalRunnerScanner › .runner file: \(runnerName) at \(workFolder)")
                }
            }
        }

        log("LocalRunnerScanner › .runner files: found \(runners.count) runner(s)")
        return runners
    }

    // MARK: - Source 3: Live process check

    /// Scans for running Runner.Listener processes and returns their names.
    private static func scanRunningProcesses() -> Set<String> {
        var runningNames: Set<String> = []

        // ps aux | grep Runner.Listener | grep -v grep
        let output = shell("ps aux | grep Runner.Listener | grep -v grep", timeout: 5)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            // Extract runner name from process arguments
            // Typical format: .../bin/Runner.Listener --name <runnerName>
            if let nameRange = extractRunnerName(from: line) {
                runningNames.insert(nameRange)
            }
        }

        log("LocalRunnerScanner › running processes: found \(runningNames.count) runner(s)")
        return runningNames
    }

    /// Extracts runner name from ps aux output line.
    private static func extractRunnerName(from line: String) -> String? {
        // Look for --name flag followed by the runner name
        let components = line.components(separatedBy: " ").filter { !$0.isEmpty }
        for (idx, component) in components.enumerated() {
            if component == "--name" && idx + 1 < components.count {
                return components[idx + 1]
            }
        }
        return nil
    }

    // MARK: - Deduplication

    /// Creates a deduplication key from runner info.
    private static func makeDedupKey(_ runner: LocalRunnerInfo) -> String {
        // Prefer agentId-based key if available
        if let agentId = runner.agentId {
            return "id:\(agentId)"
        }
        // Fall back to name + URL combo
        return "name:\(runner.name)@\(runner.gitHubUrl)"
    }
}
