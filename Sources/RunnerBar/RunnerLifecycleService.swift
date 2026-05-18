import Foundation

// MARK: - LifecycleResult

enum LifecycleResult {
    case success
    /// svc.sh returned "Must run from runner root" — the .runner config is missing or corrupt.
    case corruptInstall
    /// svc.sh ran but produced a recognisable non-corrupt error (e.g. identity mismatch).
    case failed(String)
}

// MARK: - RunnerLifecycleService

// swiftlint:disable:next type_body_length
struct RunnerLifecycleService {
    static let shared = RunnerLifecycleService()
    private init() {}

    // MARK: - Start (Resume)

    /// Starts the runner service.
    /// svc.sh install bootstraps the LaunchAgent plist, svc.sh start then loads+starts it.
    /// Both steps are required — start alone silently fails if the service was never installed.
    @discardableResult
    func start(runner: RunnerModel) -> LifecycleResult {
        log("RunnerLifecycle › START called runner=\(runner.runnerName) installPath=\(runner.installPath ?? \"nil\") gitHubUrl=\(runner.gitHubUrl ?? \"nil\")")
        guard let path = runner.installPath else {
            log("RunnerLifecycle › START abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)
        let svcSh = dir.appendingPathComponent("svc.sh").path
        log("RunnerLifecycle › START svc.sh path=\(svcSh) exists=\(FileManager.default.fileExists(atPath: svcSh)) executable=\(FileManager.default.isExecutableFile(atPath: svcSh))")

        // Step 1: install the LaunchAgent service (idempotent — safe to run even if already installed)
        log("RunnerLifecycle › START step1: svc.sh install")
        let (installOk, installOutput) = runScriptWithOutput(
            executableName: "svc.sh", arguments: ["install"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh install")
        log("RunnerLifecycle › START step1 install result=\(installOk) (non-fatal if already installed)")

        if isCorruptInstall(output: installOutput) {
            log("RunnerLifecycle › START — corruptInstall detected in install output for \(runner.runnerName)")
            return .corruptInstall
        }

        // Step 2: start the service
        log("RunnerLifecycle › START step2: svc.sh start")
        let (startOk, startOutput) = runScriptWithOutput(
            executableName: "svc.sh", arguments: ["start"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh start")
        log("RunnerLifecycle › START step2 start result=\(startOk)")

        if isCorruptInstall(output: startOutput) {
            log("RunnerLifecycle › START — corruptInstall detected in start output for \(runner.runnerName)")
            return .corruptInstall
        }

        log("RunnerLifecycle › START done: installOk=\(installOk) startOk=\(startOk) returning=\(startOk) for \(runner.runnerName)")
        if startOk { return .success }
        let msg = startOutput.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to start"
        return .failed(msg)
    }

    // MARK: - Stop

    /// Stops the runner service.
    /// svc.sh stop unloads it; svc.sh uninstall removes the LaunchAgent plist.
    /// Both steps are attempted; stop alone leaves the plist so it auto-relaunches on login.
    @discardableResult
    func stop(runner: RunnerModel) -> LifecycleResult {
        log("RunnerLifecycle › STOP called runner=\(runner.runnerName) installPath=\(runner.installPath ?? \"nil\")")
        guard let path = runner.installPath else {
            log("RunnerLifecycle › STOP abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)
        let svcSh = dir.appendingPathComponent("svc.sh").path
        log("RunnerLifecycle › STOP svc.sh path=\(svcSh) exists=\(FileManager.default.fileExists(atPath: svcSh)) executable=\(FileManager.default.isExecutableFile(atPath: svcSh))")

        // Step 1: stop the service
        log("RunnerLifecycle › STOP step1: svc.sh stop")
        let (stopOk, stopOutput) = runScriptWithOutput(
            executableName: "svc.sh", arguments: ["stop"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh stop")
        log("RunnerLifecycle › STOP step1 stop result=\(stopOk)")

        if isCorruptInstall(output: stopOutput) {
            log("RunnerLifecycle › STOP — corruptInstall detected in stop output for \(runner.runnerName)")
            return .corruptInstall
        }

        // Step 2: uninstall the LaunchAgent so it doesn't auto-restart on login
        log("RunnerLifecycle › STOP step2: svc.sh uninstall")
        let (uninstallOk, _) = runScriptWithOutput(
            executableName: "svc.sh", arguments: ["uninstall"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh uninstall")
        log("RunnerLifecycle › STOP step2 uninstall result=\(uninstallOk) (non-fatal)")
        log("RunnerLifecycle › STOP done: stopOk=\(stopOk) uninstallOk=\(uninstallOk) returning=\(stopOk) for \(runner.runnerName)")
        if stopOk { return .success }
        let msg = stopOutput.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to stop"
        return .failed(msg)
    }

    // MARK: - Remove

    /// De-registers and uninstalls the runner.
    @discardableResult
    func remove(runner: RunnerModel) -> Bool {
        log("RunnerLifecycle › REMOVE called runner=\(runner.runnerName) installPath=\(runner.installPath ?? \"nil\") gitHubUrl=\(runner.gitHubUrl ?? \"nil\")")
        guard let path = runner.installPath else {
            log("RunnerLifecycle › REMOVE abort — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        let svcSh = dir.appendingPathComponent("svc.sh").path
        let cfgSh = dir.appendingPathComponent("config.sh").path
        log("RunnerLifecycle › REMOVE svc.sh exists=\(FileManager.default.fileExists(atPath: svcSh)) executable=\(FileManager.default.isExecutableFile(atPath: svcSh))")
        log("RunnerLifecycle › REMOVE config.sh exists=\(FileManager.default.fileExists(atPath: cfgSh)) executable=\(FileManager.default.isExecutableFile(atPath: cfgSh))")

        log("RunnerLifecycle › REMOVE step1: svc.sh uninstall")
        let (svcOk, _) = runScriptWithOutput(executableName: "svc.sh", arguments: ["uninstall"],
                              workingDirectory: dir, timeout: 30, logTag: "svc.sh uninstall")
        log("RunnerLifecycle › REMOVE step1 result=\(svcOk) (non-fatal)")

        log("RunnerLifecycle › REMOVE step2: fetching removal token")
        guard let gitHubUrl = runner.gitHubUrl else {
            log("RunnerLifecycle › REMOVE abort — no gitHubUrl on runner \(runner.runnerName)")
            return false
        }
        let scope = scopeFromGitHubUrl(gitHubUrl)
        log("RunnerLifecycle › REMOVE scope=\(scope) from gitHubUrl=\(gitHubUrl)")
        guard let token = fetchRemovalToken(scope: scope) else {
            log("RunnerLifecycle › REMOVE abort — fetchRemovalToken returned nil for scope=\(scope)")
            return false
        }
        log("RunnerLifecycle › REMOVE step2: got removal token len=\(token.count) for scope=\(scope)")

        log("RunnerLifecycle › REMOVE step3: config.sh remove --token <token> in \(path)")
        let (cfgOk, _) = runScriptWithOutput(executableName: "config.sh", arguments: ["remove", "--token", token],
                              workingDirectory: dir, timeout: 30, logTag: "config.sh remove")
        log("RunnerLifecycle › REMOVE step3 result=\(cfgOk) for \(runner.runnerName)")

        if cfgOk {
            log("RunnerLifecycle › REMOVE step4: deleting LaunchAgent plist for \(runner.runnerName)")
            deleteLaunchAgentPlist(for: runner.runnerName)
        } else {
            log("RunnerLifecycle › REMOVE step4: skipping plist deletion — config.sh remove failed")
        }

        log("RunnerLifecycle › REMOVE done: svcOk=\(svcOk) cfgOk=\(cfgOk) returning=\(cfgOk) for \(runner.runnerName)")
        return cfgOk
    }

    // MARK: - Corrupt install detection

    private func isCorruptInstall(output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("must run from runner root") || lower.contains("install is corrupt")
    }

    // MARK: - LaunchAgent plist cleanup

    private func deleteLaunchAgentPlist(for runnerName: String) {
        let laDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        log("RunnerLifecycle › deleteLaunchAgentPlist: scanning \(laDir.path) for runnerName=\(runnerName)")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: laDir, includingPropertiesForKeys: nil) else {
            log("RunnerLifecycle › deleteLaunchAgentPlist: cannot list LaunchAgents dir at \(laDir.path)")
            return
        }
        log("RunnerLifecycle › deleteLaunchAgentPlist: found \(entries.count) entries")
        for url in entries {
            let filename = url.deletingPathExtension().lastPathComponent
            log("RunnerLifecycle › deleteLaunchAgentPlist: checking \(filename)")
            if filename.hasPrefix("actions.runner") && filename.hasSuffix("." + runnerName) {
                log("RunnerLifecycle › deleteLaunchAgentPlist: MATCH \(url.path) — deleting")
                do {
                    try FileManager.default.removeItem(at: url)
                    log("RunnerLifecycle › deleteLaunchAgentPlist: deleted \(url.path)")
                } catch {
                    log("RunnerLifecycle › deleteLaunchAgentPlist: delete FAILED for \(url.path): \(error)")
                }
            }
        }
    }

    // MARK: - Scope helper

    private func scopeFromGitHubUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else {
            log("RunnerLifecycle › scopeFromGitHubUrl: cannot parse URL \(urlString)")
            return urlString
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        log("RunnerLifecycle › scopeFromGitHubUrl: url=\(urlString) pathParts=\(parts)")
        if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        if parts.count == 1 { return parts[0] }
        log("RunnerLifecycle › scopeFromGitHubUrl: unexpected structure, returning raw")
        return urlString
    }

    // MARK: - Script runner

    /// Runs a script and returns both a success Bool and the full output string.
    @discardableResult
    private func runScriptWithOutput(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) -> (Bool, String) {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        let execPath = executableURL.path
        let cwd = workingDirectory.path
        let exists = FileManager.default.fileExists(atPath: execPath)
        let isExec = FileManager.default.isExecutableFile(atPath: execPath)
        let safeArgs: [String] = arguments.map { arg in
            if arg.hasPrefix("--") { return arg }
            if arg.count > 20 { return "<token(\(arg.count)ch)>" }
            return arg
        }
        log("RunnerLifecycle › runScript [\(logTag)]: execPath=\(execPath) exists=\(exists) executable=\(isExec) args=\(safeArgs) cwd=\(cwd)")
        guard isExec else {
            log("RunnerLifecycle › runScript [\(logTag)]: ABORT — not executable: \(execPath)")
            return (false, "")
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
            log("RunnerLifecycle › runScript [\(logTag)]: launched pid=\(task.processIdentifier)")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("RunnerLifecycle › runScript [\(logTag)]: launch FAILED: \(error)")
            return (false, "")
        }
        let timeoutItem = DispatchWorkItem {
            log("RunnerLifecycle › runScript [\(logTag)]: TIMEOUT after \(timeout)s — terminating pid=\(task.processIdentifier)")
            task.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        log("RunnerLifecycle › runScript [\(logTag)]: exit=\(task.terminationStatus) output=\(output.prefix(500))")
        return (task.terminationStatus == 0, output)
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
