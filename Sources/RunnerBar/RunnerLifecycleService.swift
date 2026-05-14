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

    /// The shared `RunnerLifecycleService` instance used throughout the app.
    static let shared = RunnerLifecycleService()
    private init() {
        // Singleton — use RunnerLifecycleService.shared.
    }

    // MARK: - launchctl label helper

    /// Derives the launchd service label for a runner from its name and
    /// gitHubUrl. The label format used by the runner agent installer is:
    /// `actions.runner.<owner>.<repo>.<runnerName>` for repo-scoped runners, or
    /// `actions.runner.<org>.<runnerName>` for org-scoped runners.
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

    /// Looks up the exact launchd label for this runner by running
    /// `launchctl list` via Process (no shell, no grep) and filtering
    /// the output lines in Swift.
    private func resolvedLabel(for runner: RunnerModel) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: BinaryPaths.launchctl)
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch {
            log("RunnerLifecycle › resolvedLabel: launchctl list failed: \(error)")
            return serviceLabel(for: runner)
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let exactSuffix = "." + runner.runnerName
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 3 else { continue }
            let label = cols[2].trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("actions.runner") && label.hasSuffix(exactSuffix) {
                return label
            }
        }
        return serviceLabel(for: runner)
    }

    // MARK: - Start

    /// Starts the runner’s launchd service.
    /// Returns `true` when `launchctl start` exits with status 0, `false` otherwise.
    @discardableResult
    func start(runner: RunnerModel) -> Bool {
        guard let label = resolvedLabel(for: runner) else {
            log("RunnerLifecycle › start: no label for \(runner.runnerName)")
            return false
        }
        return runLaunchctl("start", label: label)
    }

    // MARK: - Stop

    /// Stops the runner’s launchd service.
    /// Returns `true` when `launchctl stop` exits with status 0, `false` otherwise.
    @discardableResult
    func stop(runner: RunnerModel) -> Bool {
        guard let label = resolvedLabel(for: runner) else {
            log("RunnerLifecycle › stop: no label for \(runner.runnerName)")
            return false
        }
        return runLaunchctl("stop", label: label)
    }

    // MARK: - launchctl runner

    /// Invokes `launchctl <subcommand> <label>` via Process (no shell
    /// interpolation) and returns `true` iff the exit status is 0.
    @discardableResult
    private func runLaunchctl(_ subcommand: String, label: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: BinaryPaths.launchctl)
        task.arguments = [subcommand, label]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch {
            log("RunnerLifecycle › launchctl \(subcommand) \(label) launch error: \(error)")
            return false
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        log("RunnerLifecycle › launchctl \(subcommand) \(label) exit=\(task.terminationStatus): \(output.prefix(120))")
        return task.terminationStatus == 0
    }

    // MARK: - Remove

    /// Uninstalls and de-registers the runner.
    @discardableResult
    func remove(runner: RunnerModel) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › remove: no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        let svcOk = runScript(executableName: "svc.sh",
                              arguments: ["uninstall"],
                              workingDirectory: dir,
                              timeout: 30,
                              logTag: "svc.sh uninstall")
        if !svcOk {
            log("RunnerLifecycle › remove: svc.sh uninstall failed for \(runner.runnerName)")
            log("RunnerLifecycle › remove: proceeding to config.sh remove")
        }
        let cfgOk = runScript(executableName: "config.sh",
                              arguments: ["remove", "--unattended"],
                              workingDirectory: dir,
                              timeout: 30,
                              logTag: "config.sh remove")
        return svcOk && cfgOk
    }

    /// Launches `<workingDirectory>/<executableName>` via `Process.arguments`.
    /// Blocking — always call from a background thread.
    private func runScript(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) -> Bool {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        let task = Process()
        task.executableURL = executableURL
        task.currentDirectoryURL = workingDirectory
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        var outputData = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outputData.append(chunk); lock.unlock()
        }
        do { try task.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("RunnerLifecycle › \(logTag) launch error: \(error)")
            return false
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        log("RunnerLifecycle › \(logTag) exit=\(task.terminationStatus): \(output.prefix(120))")
        return task.terminationStatus == 0
    }

    // MARK: - Rename (Phase 2 — incomplete, private)

    @discardableResult
    private func rename(runner: RunnerModel, newName: String) -> Bool {
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

    /// Writes updated labels and workFolder to the `.runner` JSON at `installPath`.
    ///
    /// Note: the runner agent caches config in memory — changes take effect after
    /// the next runner restart.
    ///
    /// Phase 2 follow-up (#253): add `customLabels` to `RunnerJSON` in
    /// `LocalRunnerScanner` so labels written here are re-read on the next scan
    /// and reflected in `RunnerModel.labels`.
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
