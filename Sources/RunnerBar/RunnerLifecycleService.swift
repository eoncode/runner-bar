import Foundation

// MARK: - RunnerLifecycleService

struct RunnerLifecycleService {
    static let shared = RunnerLifecycleService()
    private init() {}

    // MARK: - Start (Resume)

    @discardableResult
    func start(runner: RunnerModel) -> Bool {
        log("RunnerLifecycle › START called runner=\(runner.runnerName) installPath=\(runner.installPath ?? "nil") gitHubUrl=\(runner.gitHubUrl ?? "nil")")
        guard let path = runner.installPath else {
            log("RunnerLifecycle › START abort — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        let svcSh = dir.appendingPathComponent("svc.sh").path
        log("RunnerLifecycle › START checking svc.sh exists at \(svcSh): \(FileManager.default.fileExists(atPath: svcSh))")
        log("RunnerLifecycle › START checking svc.sh executable: \(FileManager.default.isExecutableFile(atPath: svcSh))")
        let ok = runScript(executableName: "svc.sh", arguments: ["start"],
                           workingDirectory: dir, timeout: 15, logTag: "svc.sh start")
        log("RunnerLifecycle › START result=\(ok) for \(runner.runnerName)")
        return ok
    }

    // MARK: - Stop

    @discardableResult
    func stop(runner: RunnerModel) -> Bool {
        log("RunnerLifecycle › STOP called runner=\(runner.runnerName) installPath=\(runner.installPath ?? "nil")")
        guard let path = runner.installPath else {
            log("RunnerLifecycle › STOP abort — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        let ok = runScript(executableName: "svc.sh", arguments: ["stop"],
                           workingDirectory: dir, timeout: 15, logTag: "svc.sh stop")
        log("RunnerLifecycle › STOP result=\(ok) for \(runner.runnerName)")
        return ok
    }

    // MARK: - Remove

    /// De-registers and uninstalls the runner.
    ///
    /// Steps:
    ///   1. svc.sh uninstall  — remove LaunchAgent service (failure is non-fatal)
    ///   2. Fetch a removal token from GitHub API
    ///   3. config.sh remove --token <token>  — de-register from GitHub
    ///   4. Delete the LaunchAgent plist so the runner doesn't re-appear on next scan
    ///
    /// Returns true if config.sh remove succeeds (step 3).
    /// svc.sh uninstall failure (step 1) is non-fatal and does not affect the return value.
    @discardableResult
    func remove(runner: RunnerModel) -> Bool {
        log("RunnerLifecycle › REMOVE called runner=\(runner.runnerName) installPath=\(runner.installPath ?? "nil") gitHubUrl=\(runner.gitHubUrl ?? "nil")")

        guard let path = runner.installPath else {
            log("RunnerLifecycle › REMOVE abort — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)

        // Step 1: svc.sh uninstall (non-fatal)
        log("RunnerLifecycle › REMOVE step1: svc.sh uninstall in \(path)")
        let svcSh = dir.appendingPathComponent("svc.sh").path
        log("RunnerLifecycle › REMOVE svc.sh exists=\(FileManager.default.fileExists(atPath: svcSh)) executable=\(FileManager.default.isExecutableFile(atPath: svcSh))")
        let svcOk = runScript(executableName: "svc.sh", arguments: ["uninstall"],
                              workingDirectory: dir, timeout: 30, logTag: "svc.sh uninstall")
        log("RunnerLifecycle › REMOVE step1 result=\(svcOk) (non-fatal)")

        // Step 2: fetch removal token
        log("RunnerLifecycle › REMOVE step2: fetching removal token")
        guard let gitHubUrl = runner.gitHubUrl else {
            log("RunnerLifecycle › REMOVE abort — no gitHubUrl on runner \(runner.runnerName), cannot get removal token")
            return false
        }
        let scope = scopeFromGitHubUrl(gitHubUrl)
        log("RunnerLifecycle › REMOVE scope=\(scope) derived from gitHubUrl=\(gitHubUrl)")
        guard let token = fetchRemovalToken(scope: scope) else {
            log("RunnerLifecycle › REMOVE abort — fetchRemovalToken returned nil for scope=\(scope)")
            return false
        }
        log("RunnerLifecycle › REMOVE step2: got removal token (len=\(token.count)) for scope=\(scope)")

        // Step 3: config.sh remove --token <token>
        let cfgSh = dir.appendingPathComponent("config.sh").path
        log("RunnerLifecycle › REMOVE step3: config.sh exists=\(FileManager.default.fileExists(atPath: cfgSh)) executable=\(FileManager.default.isExecutableFile(atPath: cfgSh))")
        log("RunnerLifecycle › REMOVE step3: running config.sh remove --token <token> in \(path)")
        let cfgOk = runScript(executableName: "config.sh", arguments: ["remove", "--token", token],
                              workingDirectory: dir, timeout: 30, logTag: "config.sh remove")
        log("RunnerLifecycle › REMOVE step3 result=\(cfgOk) for \(runner.runnerName)")

        // Step 4: delete LaunchAgent plist so runner doesn't reappear on next scan
        if cfgOk {
            log("RunnerLifecycle › REMOVE step4: deleting LaunchAgent plist for \(runner.runnerName)")
            deleteLaunchAgentPlist(for: runner.runnerName)
        } else {
            log("RunnerLifecycle › REMOVE step4: skipping plist deletion because config.sh remove failed")
        }

        log("RunnerLifecycle › REMOVE done: svcOk=\(svcOk) cfgOk=\(cfgOk) returning=\(cfgOk)")
        // Return cfgOk only — svc.sh failure is non-fatal (service may already be unloaded)
        return cfgOk
    }

    // MARK: - LaunchAgent plist cleanup

    private func deleteLaunchAgentPlist(for runnerName: String) {
        let laDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: laDir, includingPropertiesForKeys: nil) else {
            log("RunnerLifecycle › deleteLaunchAgentPlist: cannot list LaunchAgents dir")
            return
        }
        log("RunnerLifecycle › deleteLaunchAgentPlist: scanning \(entries.count) entries for runnerName=\(runnerName)")
        for url in entries {
            let filename = url.deletingPathExtension().lastPathComponent
            log("RunnerLifecycle › deleteLaunchAgentPlist: checking \(filename)")
            if filename.hasPrefix("actions.runner") && filename.hasSuffix("." + runnerName) {
                log("RunnerLifecycle › deleteLaunchAgentPlist: MATCH found, deleting \(url.path)")
                do {
                    try FileManager.default.removeItem(at: url)
                    log("RunnerLifecycle › deleteLaunchAgentPlist: deleted \(url.path)")
                } catch {
                    log("RunnerLifecycle › deleteLaunchAgentPlist: delete failed for \(url.path): \(error)")
                }
            }
        }
    }

    // MARK: - Scope helper

    private func scopeFromGitHubUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else {
            log("RunnerLifecycle › scopeFromGitHubUrl: could not parse URL \(urlString)")
            return urlString
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        log("RunnerLifecycle › scopeFromGitHubUrl: url=\(urlString) pathParts=\(parts)")
        if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        if parts.count == 1 { return parts[0] }
        log("RunnerLifecycle › scopeFromGitHubUrl: unexpected path structure, returning raw url")
        return urlString
    }

    // MARK: - Script runner

    @discardableResult
    private func runScript(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) -> Bool {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        let execPath = executableURL.path
        let cwd = workingDirectory.path
        let exists = FileManager.default.fileExists(atPath: execPath)
        let isExec = FileManager.default.isExecutableFile(atPath: execPath)
        // Redact token values in logs (tokens are long alphanumeric strings, not flag names)
        let safeArgs: [String] = arguments.map { arg in
            if arg.hasPrefix("--") { return arg }
            if arg.count > 20 { return "<token(\(arg.count)ch)>" }
            return arg
        }
        log("RunnerLifecycle › runScript [\(logTag)]: path=\(execPath) exists=\(exists) executable=\(isExec) args=\(safeArgs) cwd=\(cwd)")
        guard isExec else {
            log("RunnerLifecycle › runScript [\(logTag)]: ABORT — not executable or not found at \(execPath)")
            return false
        }
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
        do {
            try task.run()
            log("RunnerLifecycle › runScript [\(logTag)]: process launched pid=\(task.processIdentifier)")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("RunnerLifecycle › runScript [\(logTag)]: launch error: \(error)")
            return false
        }
        let timeoutItem = DispatchWorkItem {
            log("RunnerLifecycle › runScript [\(logTag)]: TIMEOUT after \(timeout)s — terminating")
            task.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        log("RunnerLifecycle › runScript [\(logTag)]: exit=\(task.terminationStatus) output=\(output.prefix(400))")
        return task.terminationStatus == 0
    }

    // MARK: - Rename (Phase 2 — deferred)

    @discardableResult
    private func rename(runner: RunnerModel, newName: String) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › rename: no installPath for \(runner.runnerName)")
            return false
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(".runner")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("RunnerLifecycle › rename: failed to read .runner JSON at \(path)")
            return false
        }
        json["runnerName"] = newName
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        else { return false }
        do {
            try updated.write(to: url)
            log("RunnerLifecycle › rename: \(runner.runnerName) → \(newName)")
            return true
        } catch {
            log("RunnerLifecycle › rename write error: \(error)")
            return false
        }
    }

    // MARK: - Update config

    @discardableResult
    func updateConfig(runner: RunnerModel, labels: [String], workFolder: String) -> Bool {
        guard let path = runner.installPath else {
            log("RunnerLifecycle › updateConfig: no installPath for \(runner.runnerName)")
            return false
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(".runner")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("RunnerLifecycle › updateConfig: failed to read .runner at \(path)")
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
