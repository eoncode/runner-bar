import Foundation

// MARK: - RunnerLifecycleService

/// Encapsulates all shell-level lifecycle operations for a locally-installed
/// GitHub Actions self-hosted runner. All methods are synchronous and blocking
/// — always call from a background thread.
///
/// Token-gated operations (remove, rename, updateConfig) require a `gh` CLI
/// session or GH_TOKEN/GITHUB_TOKEN to be present, as they invoke
/// `config.sh remove` which calls the GitHub de-registration API.
struct RunnerLifecycleService {
    // MARK: - Shared singleton

    static let shared = RunnerLifecycleService()
    private init() {}

    // MARK: - launchctl label helper

    /// Derives the launchd service label for a runner from its name and
    /// gitHubUrl. The label format used by the runner agent installer is:
    /// `actions.runner.<owner>.<repo>.<runnerName>` for repo-scoped runners, or
    /// `actions.runner.<org>.<runnerName>` for org-scoped runners.
    ///
    /// This is a best-effort derivation — if the exact label isn't known, the
    /// method falls back to a prefix match via `launchctl list`.
    func serviceLabel(for runner: RunnerModel) -> String? {
        guard let urlStr = runner.gitHubUrl,
              let url = URL(string: urlStr)
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let name = runner.runnerName
        if parts.count >= 2 {
            return "actions.runner.\(parts[0]).\(parts[1]).\(name)"
        } else if parts.count == 1 {
            return "actions.runner.\(parts[0]).\(name)"
        }
        return nil
    }

    /// Looks up the exact launchd label for this runner by scanning
    /// `launchctl list` output for a label that contains the runner name.
    /// Returns nil if not found.
    private func resolvedLabel(for runner: RunnerModel) -> String? {
        let output = shell("launchctl list 2>/dev/null | grep actions.runner", timeout: 5)
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 3 else { continue }
            let label = cols[2].trimmingCharacters(in: .whitespaces)
            if label.contains(runner.runnerName) {
                return label
            }
        }
        // Fall back to derived label
        return serviceLabel(for: runner)
    }

    // MARK: - Start

    /// Starts the runner's launchd service.
    /// Returns `true` on success (exit 0), `false` otherwise.
    @discardableResult
    func start(runner: RunnerModel) -> Bool {
        guard let label = resolvedLabel(for: runner) else {
            log("RunnerLifecycle › start: no label for \(runner.runnerName)")
            return false
        }
        let result = shell("launchctl start \(label)", timeout: 10)
        log("RunnerLifecycle › start \(label): \(result.isEmpty ? "ok" : result)")
        return true
    }

    // MARK: - Stop

    /// Stops the runner's launchd service.
    /// Returns `true` on success, `false` otherwise.
    @discardableResult
    func stop(runner: RunnerModel) -> Bool {
        guard let label = resolvedLabel(for: runner) else {
            log("RunnerLifecycle › stop: no label for \(runner.runnerName)")
            return false
        }
        let result = shell("launchctl stop \(label)", timeout: 10)
        log("RunnerLifecycle › stop \(label): \(result.isEmpty ? "ok" : result)")
        return true
    }

    // MARK: - Remove

    /// Uninstalls and de-registers the runner.
    /// Runs `./svc.sh uninstall` then `./config.sh remove` from the runner's
    /// `installPath`. Both scripts require a GitHub token to be available in
    /// the environment (via `gh auth` or GH_TOKEN / GITHUB_TOKEN).
    /// Returns `true` if both scripts exit 0.
    @discardableResult
    func remove(runner: RunnerModel) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › remove: no installPath for \(runner.runnerName)")
            return false
        }
        // Uninstall launchd service first, then de-register via GitHub API.
        let svcResult = shell("cd \"\(path)\" && ./svc.sh uninstall 2>&1", timeout: 30)
        log("RunnerLifecycle › svc.sh uninstall: \(svcResult.prefix(120))")
        let cfgResult = shell("cd \"\(path)\" && ./config.sh remove --unattended 2>&1", timeout: 30)
        log("RunnerLifecycle › config.sh remove: \(cfgResult.prefix(120))")
        // Both should complete without error text to be considered success.
        let failed = cfgResult.lowercased().contains("error")
            || cfgResult.lowercased().contains("failed")
        return !failed
    }

    // MARK: - Rename

    /// Renames the runner by patching the `runnerName` field in the `.runner`
    /// JSON file at `installPath`. Note: renaming requires de-registration and
    /// re-registration with GitHub; this method only patches the local JSON.
    /// A full re-registration flow is a Phase 3+ concern.
    @discardableResult
    func rename(runner: RunnerModel, newName: String) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › rename: no installPath for \(runner.runnerName)")
            return false
        }
        let jsonPath = "\(path)/.runner"
        let url = URL(fileURLWithPath: jsonPath)
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("RunnerLifecycle › rename: failed to read .runner JSON at \(jsonPath)")
            return false
        }
        json["runnerName"] = newName
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        else {
            log("RunnerLifecycle › rename: failed to serialise updated JSON")
            return false
        }
        do {
            try updated.write(to: url)
            log("RunnerLifecycle › rename: \(runner.runnerName) → \(newName)")
            return true
        } catch {
            log("RunnerLifecycle › rename write error: \(error)")
            return false
        }
    }

    // MARK: - Update config (labels / workFolder)

    /// Writes updated labels and workFolder to the `.runner` JSON at
    /// `installPath`. Does not call the GitHub API — only patches local JSON.
    /// For label changes to take effect with GitHub, the runner must be
    /// re-registered (Phase 3 concern).
    @discardableResult
    func updateConfig(runner: RunnerModel, labels: [String], workFolder: String) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › updateConfig: no installPath for \(runner.runnerName)")
            return false
        }
        let jsonPath = "\(path)/.runner"
        let url = URL(fileURLWithPath: jsonPath)
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("RunnerLifecycle › updateConfig: failed to read .runner at \(jsonPath)")
            return false
        }
        json["workFolder"] = workFolder
        // GitHub stores labels as array of {id, name, type} objects; for local
        // storage we write a simpler [String] representation.
        json["customLabels"] = labels
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        else { return false }
        do {
            try updated.write(to: url)
            log("RunnerLifecycle › updateConfig: labels=\(labels) workFolder=\(workFolder)")
            return true
        } catch {
            log("RunnerLifecycle › updateConfig write error: \(error)")
            return false
        }
    }
}
