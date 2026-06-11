// CommitRunnerEdit.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - CommitResult

/// The outcome of a `commitRunnerEdit` call.
enum CommitResult {
    /// All requested writes succeeded.
    case success
    /// One or more writes failed. `errors` contains human-readable messages.
    case failure([String])
}

// MARK: - commitRunnerEdit

/// Persists all changed fields in `draft` for `runner` as a single transaction.
///
/// Commit order:
/// 1. Labels (GitHub API) — if changed and agentId + scope are available.
///    Aborts the entire commit (returns early) if the API call fails.
///    If agentId/scope are unavailable, appends an error and continues to local writes.
/// 2. Runner JSON — workFolder + disableUpdate in one typed read-modify-write.
/// 3. Proxy files — `.proxy` and `.proxycredentials` only when changed.
///
/// Returns the `CommitResult` directly; the caller is responsible for hopping back to
/// `@MainActor` for any UI updates.
func commitRunnerEdit(
    runner: RunnerModel,
    draft: RunnerEditDraft,
    original: RunnerEditDraft
) async -> CommitResult {
    var errors: [String] = []

    // MARK: Step 1 — Labels (GitHub API)
    let labelsChanged = draft.parsedLabels != original.parsedLabels
    if labelsChanged {
        if let agentId = runner.agentId,
           let gitHubUrl = runner.gitHubUrl,
           let scope = scopeFromHtmlUrl(gitHubUrl) {
            log("commitRunnerEdit › patching labels runner=\(runner.runnerName) labels=\(draft.parsedLabels)")
            let result = await patchRunnerLabels(scope: scope, runnerID: agentId, labels: draft.parsedLabels)
            if result == nil {
                log("commitRunnerEdit › labels API failed, aborting")
                return .failure(["Failed to save labels via GitHub API"])
            }
            log("commitRunnerEdit › labels patched ok")
        } else {
            let msg = "Cannot save labels: missing agent ID or GitHub URL"
            log("commitRunnerEdit › \(msg)")
            errors.append(msg)
        }
    }

    // MARK: Step 2 — Runner JSON (workFolder + disableUpdate)
    let workFolderChanged = draft.trimmedWorkFolder != original.trimmedWorkFolder
    let autoUpdateChanged = draft.autoUpdate != original.autoUpdate
    if workFolderChanged || autoUpdateChanged {
        guard let installPath = runner.installPath else {
            errors.append("Install path unknown — cannot write runner JSON")
            return errors.isEmpty ? .success : .failure(errors)
        }
        log("commitRunnerEdit › saving .runner config installPath=\(installPath)")
        do {
            var config = try await RunnerConfigStore.shared.load(at: installPath)
            config.workFolder = draft.trimmedWorkFolder
            config.disableUpdate = !draft.autoUpdate
            try await RunnerConfigStore.shared.save(config, at: installPath)
            log("commitRunnerEdit › .runner config updated ok")
        } catch {
            errors.append("Failed to write runner configuration (.runner JSON)")
            log("commitRunnerEdit › .runner config write failed: \(error)")
        }
    }

    // MARK: Step 3 — Proxy files
    let proxyChanged = draft.proxyUrl != original.proxyUrl
        || draft.proxyUser != original.proxyUser
        || draft.proxyPassword != original.proxyPassword
    if proxyChanged {
        guard let installPath = runner.installPath else {
            errors.append("Install path unknown — cannot write proxy files")
            return errors.isEmpty ? .success : .failure(errors)
        }
        log("commitRunnerEdit › writing proxy files installPath=\(installPath)")
        let proxyOk = writeProxyFiles(
            installPath: installPath,
            url: draft.proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            user: draft.proxyUser.trimmingCharacters(in: .whitespacesAndNewlines),
            password: draft.proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !proxyOk {
            errors.append("Failed to save proxy settings")
            log("commitRunnerEdit › proxy write failed")
        } else {
            log("commitRunnerEdit › proxy files updated ok")
        }
    }

    return errors.isEmpty ? .success : .failure(errors)
}

// MARK: - Private helpers

/// Writes (or removes) `.proxy` and `.proxycredentials` files at `installPath`.
/// Removes the file when the relevant field is empty; writes atomically otherwise.
///
/// Rules:
/// - `.proxy` contains the raw URL on one line.
/// - `.proxycredentials` is only present when either user or password is non-empty,
///   written as `user\npassword\n`.
private func writeProxyFiles(
    installPath: String,
    url: String,
    user: String,
    password: String
) -> Bool {
    let base = URL(fileURLWithPath: installPath)
    let proxyURL = base.appendingPathComponent(".proxy")
    let credURL = base.appendingPathComponent(".proxycredentials")

    // Each file is written (or removed) in its own do/catch so a failure on one
    // does not mask the result of the other, and partial-write state is reported
    // accurately. Both errors are logged; false is returned if either fails.
    var ok = true

    do {
        if url.isEmpty {
            try removeIfPresent(at: proxyURL)
        } else {
            try (url + "\n").write(to: proxyURL, atomically: true, encoding: .utf8)
        }
    } catch {
        log("writeProxyFiles › .proxy write error: \(error)")
        ok = false
    }

    do {
        if user.isEmpty && password.isEmpty {
            try removeIfPresent(at: credURL)
        } else {
            let content = user + "\n" + password + "\n"
            try content.write(to: credURL, atomically: true, encoding: .utf8)
        }
    } catch {
        log("writeProxyFiles › .proxycredentials write error: \(error)")
        ok = false
    }

    return ok
}

/// Removes the file at `url` if it exists, ignoring `NSFileNoSuchFileError`.
///
/// Any other error (e.g. permissions) is **re-thrown** so callers can
/// distinguish a missing file (harmless) from a genuine I/O failure.
/// `writeProxyFiles` catches re-thrown errors and returns `false`, which
/// propagates to the commit result as an error entry.
private func removeIfPresent(at url: URL) throws {
    do {
        try FileManager.default.removeItem(at: url)
    } catch let error as NSError where error.code == NSFileNoSuchFileError {
        // File didn't exist — expected, not an error.
    }
}
