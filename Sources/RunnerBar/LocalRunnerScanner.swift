import Foundation

// MARK: - LocalRunnerScanner

/// Scans the local machine for installed GitHub Actions self-hosted runners.
/// Combines results from `.runner` JSON files, LaunchAgent plists, and
/// live `launchctl` service names to produce a deduplicated `[RunnerModel]`.
struct LocalRunnerScanner {
    private struct RunnerJSON: Decodable {
        let gitHubUrl: String?
        let runnerName: String?
        let agentId: Int?
        let workFolder: String?
    }

    /// Scans all known runner sources and returns a sorted, deduplicated list
    /// of locally installed runners with their live-service status populated.
    func scan() -> [RunnerModel] {
        var models: [String: RunnerModel] = [:]

        for model in scanRunnerJSONFiles() {
            models[model.id] = model
        }

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

        let liveLabels = scanLiveServices()
        for key in models.keys {
            if let model = models[key] {
                models[key]?.isRunning = liveLabels.contains { $0.contains(model.runnerName) }
            }
        }

        return models.values.sorted { $0.runnerName < $1.runnerName }
    }

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

    private func scanRunnerJSONFiles() -> [RunnerModel] {
        // ⚠️ PERMISSION GUARD: ONLY scan explicit known-safe directories.
        // ❌ NEVER use `find ~` — traversing ~ hits ~/Desktop, ~/Documents, ~/Pictures
        //    which triggers macOS TCC permission dialogs (Desktop access, Photos Library,
        //    Apple Music etc.) on EVERY scan. This causes the spam permission popups.
        // ❌ NEVER scan /opt or /usr/local either — those trigger automation TCC dialogs.
        // Safe paths: ~/actions-runner* globs and ~/.runner (bare install).
        // Runners almost universally install to ~/actions-runner or ~/actions-runner-<name>.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Build candidate dirs: all ~/actions-runner* directories + bare ~/
        var candidateDirs: [String] = []

        // enumerate only the home directory's immediate children (depth 1)
        if let top = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for entry in top {
                if entry.hasPrefix("actions-runner") {
                    candidateDirs.append((home as NSString).appendingPathComponent(entry))
                }
            }
        }
        // Also check bare home (some installs put .runner directly in ~/)
        candidateDirs.append(home)

        var results: [RunnerModel] = []
        for dir in candidateDirs {
            let runnerFile = (dir as NSString).appendingPathComponent(".runner")
            guard FileManager.default.fileExists(atPath: runnerFile),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: runnerFile)),
                  let json = try? JSONDecoder().decode(RunnerJSON.self, from: data)
            else { continue }
            let name = json.runnerName ?? (dir as NSString).lastPathComponent
            results.append(RunnerModel(
                runnerName: name,
                gitHubUrl: json.gitHubUrl,
                agentId: json.agentId,
                workFolder: json.workFolder,
                installPath: dir,
                isRunning: false
            ))
        }
        return results
    }

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
