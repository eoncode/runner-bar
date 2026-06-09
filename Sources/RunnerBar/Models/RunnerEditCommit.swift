// RunnerEditCommit.swift
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
/// 2. Runner JSON — workFolder + disableUpdate in one read-modify-write.
/// 3. Proxy files — `.proxy` and `.proxycredentials` only when changed.
///
/// Must be called from a non-`@MainActor` async context (or wrapped in `Task.detached`)
/// because the file-I/O helpers (`patchRunnerJSONMulti`, `writeProxyFiles`) are blocking.
/// Returns the `CommitResult` directly; the caller is responsible for hopping back to
/// `@MainActor` for any UI updates.
/// - Warning: File I/O — always call from `Task.detached`, never from `@MainActor`.
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
            // agentId or gitHubUrl unavailable — cannot call the API.
            // Non-fatal: append an error and continue with local file writes
            // so workFolder/proxy changes are not silently discarded.
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
        log("commitRunnerEdit › patching .runner JSON installPath=\(installPath)")
        // patches uses [String: Any] to support mixed String + Bool values
        // in a single JSON read-modify-write pass.
        let jsonOk = patchRunnerJSONMulti(
            installPath: installPath,
            patches: [
                "workFolder": draft.trimmedWorkFolder,
                "disableUpdate": !draft.autoUpdate
            ]
        )
        if !jsonOk {
            errors.append("Failed to write runner configuration (.runner JSON)")
            log("commitRunnerEdit › .runner JSON write failed")
        } else {
            log("commitRunnerEdit › .runner JSON updated ok")
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

/// Reads the `.runner` JSON at `installPath`, merges all `patches` in one pass, and writes back.
/// `patches` accepts mixed `String` and `Bool` values via `Any` — this is intentional to allow
/// updating both `workFolder` (String) and `disableUpdate` (Bool) in a single read-modify-write.
private func patchRunnerJSONMulti(installPath: String, patches: [String: Any]) -> Bool {
    let url = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
    guard let data = try? Data(contentsOf: url),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        log("patchRunnerJSONMulti › failed to read \(url.path)")
        return false
    }
    for (key, value) in patches { json[key] = value }
    guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
        log("patchRunnerJSONMulti › serialization failed")
        return false
    }
    do {
        try newData.write(to: url, options: .atomic)
        log("patchRunnerJSONMulti › wrote keys=\(patches.keys.sorted()) to \(url.path)")
        return true
    } catch {
        log("patchRunnerJSONMulti › write error: \(error)")
        return false
    }
}

/// Writes (or removes) `.proxy` and `.proxycredentials` files at `installPath`.
/// Removes the file when the relevant field is empty; writes otherwise.
private func writeProxyFiles(installPath: String, url: String, user: String, password: String) -> Bool {
    var ok = true
    let base = URL(fileURLWithPath: installPath)
    let proxyURL = base.appendingPathComponent(".proxy")
    let credURL = base.appendingPathComponent(".proxycredentials")

    // .proxy — contains the raw proxy URL on a single line
    do {
        if url.isEmpty {
            do {
                try FileManager.default.removeItem(at: proxyURL)
                log("writeProxyFiles › removed .proxy")
            } catch let err as NSError where err.code == NSFileNoSuchFileError {
                // file already absent — no-op
            } catch {
                log("writeProxyFiles › failed to remove .proxy: \(error)")
                ok = false
            }
        } else {
            try url.write(to: proxyURL, atomically: true, encoding: .utf8)
            log("writeProxyFiles › wrote .proxy")
        }
    } catch {
        // only reached on write failure (the remove path has its own inner do/catch)
        log("writeProxyFiles › .proxy error: \(error)")
        ok = false
    }

    // .proxycredentials — two-line format: line 1 = username, line 2 = password
    do {
        if user.isEmpty && password.isEmpty {
            do {
                try FileManager.default.removeItem(at: credURL)
                log("writeProxyFiles › removed .proxycredentials")
            } catch let err as NSError where err.code == NSFileNoSuchFileError {
                // file already absent — no-op
            } catch {
                log("writeProxyFiles › failed to remove .proxycredentials: \(error)")
                ok = false
            }
        } else {
            try "\(user)\n\(password)".write(to: credURL, atomically: true, encoding: .utf8)
            log("writeProxyFiles › wrote .proxycredentials")
        }
    } catch {
        // only reached on write failure (the remove path has its own inner do/catch)
        log("writeProxyFiles › .proxycredentials error: \(error)")
        ok = false
    }

    return ok
}
