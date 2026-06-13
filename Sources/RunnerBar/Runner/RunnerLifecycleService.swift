// RunnerLifecycleService.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - LifecycleResult

/// The result of a runner lifecycle operation (start or stop).
enum LifecycleResult {
    /// The operation completed successfully.
    case success
    /// The runner installation is corrupt (e.g. missing `svc.sh`, wrong working directory).
    /// The caller should prompt the user to reinstall the runner.
    case corruptInstall
    /// The operation failed with a human-readable reason string.
    case failed(String)
}

// MARK: - RunnerLifecycleService

/// Manages the macOS launchctl service lifecycle for locally-installed GitHub Actions runner agents.
///
/// Each runner is installed as a launchd agent via the runner's own `svc.sh` script.
/// This service drives the install → start, stop → uninstall, and full removal sequences,
/// delegating process execution to `ProcessRunner` and token fetching to the GitHub API.
struct RunnerLifecycleService {
    /// Shared singleton — use this instead of calling init directly.
    static let shared = RunnerLifecycleService()
    /// Private initialiser — use `shared`.
    private init() { /* Singleton — intentionally empty; all state is in instance properties. */ }

    // MARK: - Start

    /// Installs and starts the launchd service for `runner` by running `svc.sh install` then `svc.sh start`.
    ///
    /// Returns `.corruptInstall` if either step detects a broken installation,
    /// `.success` if the start step exits 0, or `.failed` with the first non-empty
    /// output line otherwise.
    @discardableResult
    func start(runner: RunnerModel) async -> LifecycleResult {
        let ip = runner.installPath ?? "nil"
        let gh = runner.gitHubUrl ?? "nil"
        logStep("START", "called runner=\(runner.runnerName) installPath=\(ip) gitHubUrl=\(gh)")
        guard let path = runner.installPath else {
            logStep("START", "abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)
        let svcPath = dir.appendingPathComponent("svc.sh").path
        logStep("START", "svc.sh=\(svcPath) exists=\(FileManager.default.fileExists(atPath: svcPath)) executable=\(FileManager.default.isExecutableFile(atPath: svcPath))")

        logStep("START", "step1: svc.sh install")
        let (installOk, installOutput) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["install"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh install")
        logStep("START", "step1 done: ok=\(installOk) output=\(installOutput.prefix(300))")
        if isCorruptInstall(output: installOutput) {
            logStep("START", "RETURNING .corruptInstall after install step for \(runner.runnerName)")
            return .corruptInstall
        }

        logStep("START", "step2: svc.sh start")
        let (startOk, startOutput) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["start"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh start")
        logStep("START", "step2 done: ok=\(startOk) output=\(startOutput.prefix(300))")
        if isCorruptInstall(output: startOutput) {
            logStep("START", "RETURNING .corruptInstall after start step for \(runner.runnerName)")
            return .corruptInstall
        }
        if startOk {
            logStep("START", "RETURNING .success for \(runner.runnerName)")
            return .success
        }
        let msg = startOutput.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to start"
        logStep("START", "RETURNING .failed(\(msg)) for \(runner.runnerName)")
        return .failed(msg)
    }

    // MARK: - Stop

    /// Stops and uninstalls the launchd service for `runner` by running `svc.sh stop` then `svc.sh uninstall`.
    ///
    /// Returns `.corruptInstall` if either step detects a broken installation,
    /// `.success` if the stop step exits 0, or `.failed` with the first non-empty
    /// output line otherwise.
    ///
    /// - Note: The uninstall step (step 2) is best-effort — its exit code does not affect the
    ///   return value because a successful `svc.sh stop` is sufficient to take the runner offline.
    ///   A corrupt-install signal from `uninstallOutput` is still surfaced as `.corruptInstall`.
    @discardableResult
    func stop(runner: RunnerModel) async -> LifecycleResult {
        let ip = runner.installPath ?? "nil"
        logStep("STOP", "called runner=\(runner.runnerName) installPath=\(ip)")
        guard let path = runner.installPath else {
            logStep("STOP", "abort — no installPath for \(runner.runnerName)")
            return .failed("Install path unknown")
        }
        let dir = URL(fileURLWithPath: path)

        logStep("STOP", "step1: svc.sh stop")
        let (stopOk, stopOutput) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["stop"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh stop")
        logStep("STOP", "step1 done: ok=\(stopOk) output=\(stopOutput.prefix(300))")
        if isCorruptInstall(output: stopOutput) {
            logStep("STOP", "RETURNING .corruptInstall after stop step for \(runner.runnerName)")
            return .corruptInstall
        }

        logStep("STOP", "step2: svc.sh uninstall")
        let (_, uninstallOutput) = await runScriptWithOutput(
            // uninstall exit code is intentionally ignored — best-effort after a successful stop.
            executableName: "svc.sh", arguments: ["uninstall"],
            workingDirectory: dir, timeout: 15, logTag: "svc.sh uninstall")
        logStep("STOP", "step2 done: output=\(uninstallOutput.prefix(300))")
        if isCorruptInstall(output: uninstallOutput) {
            logStep("STOP", "RETURNING .corruptInstall after uninstall step for \(runner.runnerName)")
            return .corruptInstall
        }

        if stopOk {
            logStep("STOP", "RETURNING .success for \(runner.runnerName)")
            return .success
        }
        let msg = stopOutput.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Failed to stop"
        logStep("STOP", "RETURNING .failed(\(msg)) for \(runner.runnerName)")
        return .failed(msg)
    }

    // MARK: - Remove

    /// Fully removes a runner: uninstalls the launchd service, deregisters it from GitHub via
    /// `config.sh remove` (falling back to the API DELETE endpoint if the script fails),
    /// deletes the install directory, and removes the LaunchAgent plist.
    ///
    /// Returns `true` if the runner was successfully deregistered from GitHub (either via
    /// `config.sh` or the API fallback). Returns `false` if deregistration failed.
    ///
    /// - Note: Returns `Bool` rather than `LifecycleResult` because removal is a best-effort
    ///   multi-step operation — partial failures (e.g. corrupt install) are handled internally
    ///   via the API fallback rather than surfaced as distinct result cases.
    /// - Note: Local file cleanup (install directory + LaunchAgent plist) is performed only
    ///   when deregistration succeeds (`removeOk == true`). If both `config.sh` and the API
    ///   fallback fail, no local files are deleted so the user can retry.
    @discardableResult
    func remove(runner: RunnerModel) async -> Bool {
        let ip = runner.installPath ?? "nil"
        let gh = runner.gitHubUrl ?? "nil"
        logStep("REMOVE", "called runner=\(runner.runnerName) installPath=\(ip) gitHubUrl=\(gh)")
        guard let path = runner.installPath else {
            logStep("REMOVE", "abort — no installPath for \(runner.runnerName)")
            return false
        }
        let dir = URL(fileURLWithPath: path)

        logStep("REMOVE", "step1: svc.sh uninstall")
        let (svcOk, _) = await runScriptWithOutput(
            executableName: "svc.sh", arguments: ["uninstall"],
            workingDirectory: dir, timeout: 30, logTag: "svc.sh uninstall")
        logStep("REMOVE", "step1 result=\(svcOk) (non-fatal)")

        guard let gitHubUrl = runner.gitHubUrl else {
            logStep("REMOVE", "abort — no gitHubUrl on runner \(runner.runnerName)")
            return false
        }
        let scopeString = scopeFromGitHubUrl(gitHubUrl)

        logStep("REMOVE", "step2: fetching removal token for scope=\(scopeString)")
        guard let token = await fetchRemovalToken(scope: scopeString) else {
            logStep("REMOVE", "abort — fetchRemovalToken returned nil for scope=\(scopeString)")
            return false
        }
        logStep("REMOVE", "step2: got token len=\(token.count)")

        logStep("REMOVE", "step3: config.sh remove --token <token> in \(path)")
        let (cfgOk, cfgOutput) = await runScriptWithOutput(
            executableName: "config.sh", arguments: ["remove", "--token", token],
            workingDirectory: dir, timeout: 30, logTag: "config.sh remove")
        logStep("REMOVE", "step3 result=\(cfgOk) for \(runner.runnerName)")

        var removeOk = cfgOk
        if !cfgOk {
            let isCorrupt = cfgOutput.contains("No such file or directory")
                || cfgOutput.contains("install is corrupt")
                || cfgOutput.contains("must run from runner root")
            logStep("REMOVE", "step3b: config.sh failed isCorrupt=\(isCorrupt) — trying API DELETE fallback")
            if let agentId = runner.agentId {
                logStep("REMOVE", "step3b: calling deleteRunnerByID scope=\(scopeString) agentId=\(agentId)")
                let apiOk = await deleteRunnerByID(scope: scopeString, runnerID: agentId)
                logStep("REMOVE", "step3b: deleteRunnerByID result=\(apiOk)")
                removeOk = apiOk
            } else {
                logStep("REMOVE", "step3b: no agentId available — cannot use API DELETE fallback")
            }
        }

        if removeOk {
            logStep("REMOVE", "step4: deleting install dir \(path)")
            do {
                try FileManager.default.removeItem(atPath: path)
                logStep("REMOVE", "step4: deleted \(path)")
            } catch {
                logStep("REMOVE", "step4: failed to delete dir \(path): \(error)")
            }
            deleteLaunchAgentPlist(for: runner.runnerName)
        } else {
            logStep("REMOVE", "step4: skipping local cleanup — deregistration failed for \(runner.runnerName)")
        }
        logStep("REMOVE", "done: svcOk=\(svcOk) cfgOk=\(cfgOk) removeOk=\(removeOk) for \(runner.runnerName)")
        return removeOk
    }

    // MARK: - Corrupt install detection

    /// Returns `true` if `output` contains a string that indicates the runner installation is corrupt
    /// (e.g. the runner was moved or partially uninstalled outside the app).
    private func isCorruptInstall(output: String) -> Bool {
        let lower = output.lowercased()
        let result = lower.contains("must run from runner root") || lower.contains("install is corrupt")
        logStep("isCorruptInstall", "result=\(result) for output prefix=\(output.prefix(100))")
        return result
    }

    // MARK: - LaunchAgent plist cleanup

    /// Removes any LaunchAgent plist file in `~/Library/LaunchAgents` whose name matches
    /// the pattern `actions.runner.*.<runnerName>`. Called as the final cleanup step in `remove()`.
    private func deleteLaunchAgentPlist(for runnerName: String) {
        let laDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: laDir, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let filename = url.deletingPathExtension().lastPathComponent
            if filename.hasPrefix("actions.runner") && filename.hasSuffix("." + runnerName) {
                try? FileManager.default.removeItem(at: url)
                logStep("deleteLaunchAgentPlist", "deleted \(url.path)")
            }
        }
    }

    // MARK: - Scope helper

    /// Derives a GitHub scope string (`owner/repo` or `org`) from a GitHub URL.
    ///
    /// Examples:
    /// - `https://github.com/acme/my-repo` → `"acme/my-repo"`
    /// - `https://github.com/acme` → `"acme"`
    /// - Unrecognised URL → returns the original string unchanged.
    private func scopeFromGitHubUrl(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        if parts.count == 1 { return parts[0] }
        return urlString
    }

    // MARK: - Script runner

    /// Runs a shell script relative to `workingDirectory` and returns `(exitCode == 0, combined output)`.
    ///
    /// Thin wrapper around `ProcessRunner.runAsync` that resolves the executable by name within the
    /// runner's install directory, guards against non-executable files, and merges stderr into stdout.
    private func runScriptWithOutput(
        executableName: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        logTag: String
    ) async -> (Bool, String) {
        let executableURL = workingDirectory.appendingPathComponent(executableName)
        let execPath = executableURL.path
        let isExec = FileManager.default.isExecutableFile(atPath: execPath)
        logStep("runScript [\(logTag)]", "execPath=\(execPath) executable=\(isExec) args=\(arguments.filter { $0.hasPrefix("--") || $0.count <= 20 }) cwd=\(workingDirectory.path)")
        guard isExec else {
            logStep("runScript [\(logTag)]", "ABORT not executable")
            return (false, "")
        }
        let result = await ProcessRunner.runAsync(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            mergeStderr: true,
            timeout: timeout
        )
        logStep("runScript [\(logTag)]", "exit=\(result.exitCode) output=\(result.output.prefix(500))")
        return (result.exitCode == 0, result.output)
    }

    // MARK: - Logging helper

    /// Emits a structured log line in the format `RunnerLifecycle > <tag>: <message>`.
    /// Centralises the prefix so individual methods stay concise.
    private func logStep(_ tag: String, _ message: String) {
        log("RunnerLifecycle > \(tag): \(message)")
    }
}
