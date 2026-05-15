// swiftlint:disable file_length
import Foundation

// MARK: - LocalRunnerScanner

/// Scans the local filesystem for installed GitHub Actions self-hosted runners.
/// Reads `.runner` JSON files and correlates with launchctl service state.
enum LocalRunnerScanner {
    /// Scans all known runner install paths and returns a list of `RunnerModel` values.
    static func scan() -> [RunnerModel] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchRoots = [
            home,
            "\(home)/runners",
            "\(home)/actions-runner",
            "/opt/runners",
            "/usr/local/runners"
        ]
        var found: [RunnerModel] = []
        var seenPaths = Set<String>()
        for root in searchRoots {
            scan(directory: root, found: &found, seenPaths: &seenPaths)
        }
        log("LocalRunnerScanner.scan → \(found.count) runner(s)")
        return found
    }

    private static func scan(
        directory: String,
        found: inout [RunnerModel],
        seenPaths: inout Set<String>
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for item in items {
            let fullPath = "\(directory)/\(item)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let runnerFile = "\(fullPath)/.runner"
            if fm.fileExists(atPath: runnerFile) {
                if seenPaths.insert(fullPath).inserted {
                    if let model = parseRunner(at: fullPath) { found.append(model) }
                }
            }
        }
    }

    private static func parseRunner(at path: String) -> RunnerModel? {
        let runnerFile = "\(path)/.runner"
        guard let data = FileManager.default.contents(atPath: runnerFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let name = json["agentName"] as? String ?? (path as NSString).lastPathComponent
        let gitHubUrl = json["gitHubUrl"] as? String
        let agentId = json["agentId"] as? Int
        let workFolder = json["workFolder"] as? String
        let isRunning = launchdIsRunning(installPath: path)
        return RunnerModel(
            runnerName: name,
            gitHubUrl: gitHubUrl,
            agentId: agentId,
            workFolder: workFolder,
            installPath: path,
            isRunning: isRunning
        )
    }

    private static func launchdIsRunning(installPath: String) -> Bool {
        let label = launchdLabel(for: installPath)
        let result = shell("launchctl list \(label) 2>/dev/null")
        return !result.isEmpty && !result.contains("Could not find service")
    }

    private static func launchdLabel(for installPath: String) -> String {
        let name = (installPath as NSString).lastPathComponent
        return "actions.runner.\(name)"
    }
}
// swiftlint:enable file_length
