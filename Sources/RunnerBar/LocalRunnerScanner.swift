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
        // ⚠️ PERMISSION GUARD: search only ~ (home directory).
        // ❌ NEVER add /opt or /usr/local — those paths trigger macOS TCC
        //    automation permission dialogs every time Settings opens.
        //    Runners installed outside ~ are rare and not worth the UX cost.
        let raw = shell(
            "find ~ -maxdepth 6 -name '.runner' 2>/dev/null",
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
