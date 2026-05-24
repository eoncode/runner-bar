// RunnerLifecycleService.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - LifecycleResult

/// Enumerates possible outcomes of a runner lifecycle operation.
enum LifecycleResult {
    /// The operation completed successfully.
    case success
    /// The runner install directory is corrupt or incomplete.
    case corruptInstall
    /// The operation failed with a human-readable reason.
    case failed(String)
}

// MARK: - RunnerLifecycleService

// swiftlint:disable:next type_body_length
/// Manages start, stop, and remove lifecycle operations for local GitHub Actions runners.
struct RunnerLifecycleService {
    /// The shared singleton instance.
    static let shared = RunnerLifecycleService()
    /// Private initialiser — use `shared`.
    private init() {}

    // MARK: - Start

    /// Starts the runner service using `svc.sh install` then `svc.sh start`.
    /// Returns `.corruptInstall` if svc.sh detects a broken install, `.success` on success.
    @discardableResult
    func start(runner: RunnerModel) -> LifecycleResult {
        let ip = runner.installPath ?? "nil"
        let gh = runner.gitHubUrl ?? "nil"
        log("RunnerLifecycle > START called runner=\(runner.runnerName) installPath=\(ip) gitHubUrl=\(gh)")
        guard let path = runner.installPath else {
            log("RunnerLifecycle > START abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)
        let svcPath = dir.appendingPathComponent("svc.sh").path
        let svcExists = FileManager.default.fileExists(atPath: svcPath)
        let svcExec = FileManager.default.isExecutableFile(atPath: svcPath)
        log("RunnerLifecycle > START svc.sh=\(svcPath) exists=\(svcExists) executable=\(svcExec)")
        log("RunnerLifecycle > START step1: svc.sh install")
        let (installOk, installOutput) = runScriptWithOutput(
            executableName: "svc.sh",
            arguments: ["install"],
            workingDirectory: dir,
            timeout: 15,
            logTag: "svc.sh install")
        log("RunnerLifecycle > START step1 done: ok=\(installOk) output=\(installOutput.prefix(300))")
        log("RunnerLifecycle > START step1 corruptCheck: isCorrupt=\(isCorruptInstall(output: installOutput))")
        if isCorruptInstall(output: installOutput) {
            log("RunnerLifecycle > START RETURNING .corruptInstall after install step for \(runner.runnerName)")
            return .corruptInstall
        }
        log("RunnerLifecycle > START step2: svc.sh start")
        let (startOk, startOutput) = runScriptWithOutput(
            executableName: "svc.sh",
            arguments: ["start"],
            workingDirectory: dir,
            timeout: 15,
            logTag: "svc.sh start")
        log("RunnerLifecycle > START step2 done: ok=\(startOk) output=\(startOutput.prefix(300))")
        log("RunnerLifecycle > START step2 corruptCheck: isCorrupt=\(isCorruptInstall(output: startOutput))")
        if isCorruptInstall(output: startOutput) {
            log("RunnerLifecycle > START RETURNING .corruptInstall after start step for \(runner.runnerName)")
            return .corruptInstall
        }
        if startOk {
            log("RunnerLifecycle > START RETURNING .success for \(runner.runnerName)")
            return .success
        }
        let msg = startOutput.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to start"
        log("RunnerLifecycle > START RETURNING .failed(\(msg)) for \(runner.runnerName)")
        return .failed(msg)
    }

    // MARK: - Stop

    /// Stops the runner service using `svc.sh stop` then `svc.sh uninstall`.
    /// Returns `.corruptInstall` if svc.sh detects a broken install, `.success` on success.
    @discardableResult
    func stop(runner: RunnerModel) -> LifecycleResult {
        let ip = runner.installPath ?? "nil"
        log("RunnerLifecycle > STOP called runner=\(runner.runnerName) installPath=\(ip)")
        guard let path = runner.installPath else {
            log("RunnerLifecycle > STOP abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)
        log("RunnerLifecycle > STOP step1: svc.sh stop")
        let (stopOk, stopOutput) = runScriptWithOutput(
            executableName: "svc.sh",
            arguments: ["stop"],
            workingDirectory: dir,
            timeout: 15,
            logTag: "svc.sh stop")
        log("RunnerLifecycle > STOP step1 done: ok=\(stopOk) output=\(stopOutput.prefix(300))")
        if isCorruptInstall(output: stopOutput) {
            log("RunnerLifecycle > STOP RETURNING .corruptInstall for \(runner.runnerName)")
            return .corruptInstall
        }
        log("RunnerLifecycle > STOP step2: svc.sh uninstall")
        let (uninstallOk, uninstallOutput) = runScriptWithOutput(
            executableName: "svc.sh",
            arguments: ["uninstall"],
            workingDirectory: dir,
            timeout: 15,
            logTag: "svc.sh uninstall")
        log("RunnerLifecycle > STOP step2 done: ok=\(uninstallOk) output=\(uninstallOutput.prefix(300))")
        if stopOk {
            log("RunnerLifecycle > STOP RETURNING .success for \(runner.runnerName)")
            return .success
        }
        let msg = stopOutput.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to stop"
        log("RunnerLifecycle > STOP RETURNING .failed(\(msg)) for \(runner.runnerName)")
        return .failed(msg)
    }

    // MARK: - Remove

    /// Removes the runner: uninstalls the service, calls the GitHub API removal token,
    /// runs `config.sh remove`, deletes the install directory, and cleans up LaunchAgent plists.
    @discardableResult
    func remove(runner: RunnerModel) -> Bool {
        let ip = runner.installPath ?? "nil"
        let gh = runner.gitHubUrl ?? "nil"
        log("RunnerLifecycle > REMOVE called runner=\(runner.runnerName) installPath=\(ip) gitHubUrl=\(gh)")
        guard let path = runner.installPath else {
            log("RunnerLifecycle > REMOVE abort — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)
        log("RunnerLifecycle > REMOVE step1: svc.sh uninstall")
        let (svcOk, _) = runScriptWithOutput(executableName: "svc.sh", arguments: ["uninstall"], workingDirectory: dir, timeout: 30, logTag: "svc.sh uninstall")
        log("RunnerLifecycle > REMOVE step1 result=\(svcOk) (non-fatal)")
        guard let gitHubUrl = runner.gitHubUrl else {
            log("RunnerLifecycle > REMOVE abort — no gitHubUrl on runner \(runner.runnerName)")
            return false
        }
        let scopeString = scopeFromGitHubUrl(gitHubUrl)
        log("RunnerLifecycle > REMOVE step2: fetching removal token for scope=\(scopeString)")
        guard let token = fetchRemovalToken(scope: scopeString) else {
            log("RunnerLifecycle > REMOVE abort — fetchRemovalToken returned nil for scope=\(scopeString)")
            return false
        }
        log("RunnerLifecycle > REMOVE step2: got token len=\(token.count)")
        log("RunnerLifecycle > REMOVE step3: config.sh remove --token <token> in \(path)")
        let (cfgOk, cfgOutput) = runScriptWithOutput(executableName: "config.sh", arguments: ["remove", "--token", token], workingDirectory: dir, timeout: 30, logTag: "config.sh remove")
        log("RunnerLifecycle > REMOVE step3 result=\(cfgOk) for \(runner.runnerName)")
        var removeOk = cfgOk
        if !cfgOk {
            let isCorrupt = cfgOutput.contains("No such file or directory")
                || cfgOutput.contains("install is corrupt")
                || cfgOutput.contains("must run from runner root")
            log("RunnerLifecycle > REMOVE step3b: config.sh failed isCorrupt=\(isCorrupt) — trying API DELETE fallback")
            if let agentId = runner.agentId {
                log("RunnerLifecycle > REMOVE step3b: calling deleteRunnerByID scope=\(scopeString) agentId=\(agentId)")
                let apiOk = deleteRunnerByID(scope: scopeString, runnerID: agentId)
                log("RunnerLifecycle > REMOVE step3b: deleteRunnerByID result=\(apiOk)")
                removeOk = apiOk
            } else {
                log("RunnerLifecycle > REMOVE step3b: no agentId available — cannot use API DELETE fallback")
            }
        }
        if removeOk || (!cfgOk && runner.agentId != nil) {
            log("RunnerLifecycle > REMOVE step4: deleting install dir \(path)")
            do {
                try FileManager.default.removeItem(atPath: path)
                log("RunnerLifecycle > REMOVE step4: deleted \(path)")
            } catch {
                log("RunnerLifecycle > REMOVE step4: failed to delete dir \(path): \(error)")
            }
            deleteLaunchAgentPlist(for: runner.runnerName)
        }
        log("RunnerLifecycle > REMOVE done: svcOk=\(svcOk) cfgOk=\(cfgOk) removeOk=\(removeOk) for \(runner.runnerName)")
        return removeOk
    }

    // MARK: - Corrupt install detection

    /// Returns `true` when the script output indicates a corrupt runner install.
    private func isCorruptInstall(output: String) -> Bool {
        let lower = output.lowercased()
        let result = lower.contains("must run from runner root") || lower.contains("install is corrupt")
        log("RunnerLifecycle > isCorruptInstall: result=\(result) for output prefix=\(output.prefix(100))")
        return result
    }

    // MARK: - LaunchAgent plist cleanup

    /// Removes LaunchAgent plist files matching the runner name from `~/Library/LaunchAgents`.
    private func deleteLaunchAgentPlist(for runnerName: String) {
        let laDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: laDir, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let filename = url.deletingPathExtension().lastPathComponent
            if filename.hasPrefix("actions.runner") && filename.hasSuffix("." + runnerName) {
                try? FileManager.default.removeItem(at: url)
                log("RunnerLifecycle > deleteLaunchAgentPlist: deleted \(url.path)")
            }
        }
    }

    // MARK: - Scope helper

    /// Extracts a `owner/repo` or `owner` scope string from a GitHub runner registration URL.
    private func scopeFromGitHubUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        if parts.count == 1 { return parts[0] }
        return urlString
    }

    // MARK: - Script runner

    /// Runs a shell script relative to `workingDirectory` and returns `(success, output)`.
    private func runScriptWithOutput(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) -> (Bool, String) {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        let execPath = executableURL.path
        let isExec = FileManager.default.isExecutableFile(atPath: execPath)
        log("RunnerLifecycle > runScript [\(logTag)]: execPath=\(execPath) executable=\(isExec) args=\(arguments.filter { $0.hasPrefix("--") || $0.count <= 20 }) cwd=\(workingDirectory.path)")
        guard isExec else {
            log("RunnerLifecycle > runScript [\(logTag)]: ABORT not executable")
            return (false, "")
        }
        let result = ProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            mergeStderr: true,
            timeout: timeout
        )
        let output = result.output
        log("RunnerLifecycle > runScript [\(logTag)]: exit=\(result.exitCode) output=\(output.prefix(500))")
        return (result.exitCode == 0, output)
    }
}
