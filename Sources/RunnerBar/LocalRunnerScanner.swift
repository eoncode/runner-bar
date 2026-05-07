import Foundation

/// Scanner for local GitHub Actions runners.
///
/// Phase 1 discovery:
/// - Scans `~/Library/LaunchAgents/actions.runner.*.plist`
/// - Scans for `.runner` JSON files
/// - Cross-references with `ps aux` for live process state
struct LocalRunnerScanner {
    /// Discovers all runners on the machine.
    static func scan() -> [Runner] {
        var runners: [Runner] = []
        runners.append(contentsOf: scanLaunchAgents())
        runners.append(contentsOf: scanRunnerFiles())

        let runningPIDs = discoverRunningPIDs()
        for idx in runners.indices {
            if let agentId = runners[idx].agentId, runningPIDs.contains(agentId) {
                runners[idx].isRunning = true
            }
        }

        return deduplicate(runners)
    }

    /// Scans `~/Library/LaunchAgents/` for `actions.runner.*.plist` files.
    private static func scanLaunchAgents() -> [Runner] {
        let folder = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }

        return files.compactMap { file -> Runner? in
            guard file.hasPrefix("actions.runner.") && file.hasSuffix(".plist") else { return nil }
            // filename example: actions.runner.owner-repo.name.plist
            let parts = file.replacingOccurrences(of: "actions.runner.", with: "")
                            .replacingOccurrences(of: ".plist", with: "")
                            .components(separatedBy: ".")
            guard parts.count >= 2 else { return nil }
            let name = parts.last ?? "Unknown"

            // Stable ID using name string hash
            let stableId = name.utf8.reduce(5381) { ($0 << 5) &+ $0 + Int($1) }

            return Runner(
                id: stableId,
                name: name,
                status: "offline", // default, enriched later
                busy: false,
                agentId: nil,
                installPath: nil,
                isRunning: false,
                gitHubUrl: nil,
                isLocal: true
            )
        }
    }

    /// Finds `.runner` files in common locations.
    private static func scanRunnerFiles() -> [Runner] {
        // Optimized: search only specific likely locations instead of full home search
        let roots = [
            NSHomeDirectory(),
            "/opt",
            "/usr/local",
            (NSHomeDirectory() as NSString).appendingPathComponent("runners"),
            (NSHomeDirectory() as NSString).appendingPathComponent("actions-runner")
        ]
        var results: [Runner] = []

        for root in roots {
            let output = shell("find \(root) -name \".runner\" -maxdepth 3 2>/dev/null", timeout: 5)
            let paths = output.components(separatedBy: "\n").filter { !$0.isEmpty }

            for path in paths {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let name = json["runnerName"] as? String ?? "Unknown"
                let gitHubUrl = json["gitHubUrl"] as? String
                let agentId = json["agentId"] as? Int

                // Stable ID using agentId or name + url string hash
                let key = agentId.map { "\($0)" } ?? "\(name)|\(gitHubUrl ?? "")"
                let stableId = key.utf8.reduce(5381) { ($0 << 5) &+ $0 + Int($1) }

                results.append(Runner(
                    id: stableId,
                    name: name,
                    status: "offline",
                    busy: false,
                    agentId: agentId,
                    installPath: (path as NSString).deletingLastPathComponent,
                    isRunning: false,
                    gitHubUrl: gitHubUrl,
                    isLocal: true
                ))
            }
        }
        return results
    }

    /// Detects PIDs of active `Runner.Listener` processes.
    private static func discoverRunningPIDs() -> Set<Int> {
        let output = shell("ps aux | grep Runner.Listener | grep -v grep", timeout: 5)
        let lines = output.components(separatedBy: "\n")
        var pids = Set<Int>()
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count > 1, let pid = Int(parts[1]) {
                pids.insert(pid)
            }
        }
        return pids
    }

    /// Deduplicates discovered runners by `agentId` or `name` + `gitHubUrl`.
    private static func deduplicate(_ runners: [Runner]) -> [Runner] {
        var seen = Set<String>()
        var unique: [Runner] = []
        for runner in runners {
            let key = runner.agentId.map { "\($0)" } ?? "\(runner.name)|\(runner.gitHubUrl ?? "")"
            if seen.insert(key).inserted {
                unique.append(runner)
            }
        }
        return unique
    }
}
