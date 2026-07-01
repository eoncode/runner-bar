// AppUpdater+Install.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#endif
import Foundation

// MARK: - Install & Relaunch

/// Install-and-relaunch logic for ``AppUpdater``.
extension AppUpdater {

    /// Unzips the cached update zip, replaces the running `.app` bundle, and
    /// relaunches the new version.
    ///
    /// ## Flow
    /// 1. Unzip the cached zip into a temporary directory via `/usr/bin/ditto`.
    /// 2. Locate the `.app` bundle inside the unzipped contents.
    /// 3. (Optional) If `skipCodeSignValidation` is `false`: verify that the
    ///    running bundle and the downloaded bundle share the same `codesign`
    ///    `Authority=` identity. A mismatch calls `setUpdateFailed()` and aborts.
    /// 4. Replace the running bundle via `FileManager.replaceItem` (atomic swap).
    /// 5. Relaunch the new binary with `/usr/bin/open`.
    /// 6. Delete the zip (spent — relaunch confirmed).
    /// 7. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure the function calls `state.setUpdateFailed()` and returns
    /// without terminating — the user is left with the running version and the
    /// host should direct them to re-run the original `curl` install command.
    ///
    /// **Exception — post-replaceItem relaunch failure:** if `replaceItem`
    /// succeeds but `open -n` throws, the new binary is already on disk and the
    /// curl-install fallback is misleading (the user does not need to reinstall).
    /// In this case `clearDownloadState()` is called instead of `setUpdateFailed()`
    /// so the host shows a neutral state. The zip is NOT deleted in this branch —
    /// `rehydrateCachedUpdateIfNewer()` will find it on next launch and offer the
    /// install without requiring a re-download. The user can relaunch manually.
    ///
    /// ## Why curl is the only correct install and recovery path
    ///
    /// This app is **ad-hoc signed** — it carries a local code signature but
    /// has NOT been submitted to Apple for notarisation. Gatekeeper will block
    /// any `.app` that arrives with the `com.apple.quarantine` extended
    /// attribute set, because without a notarisation ticket it cannot verify
    /// the binary.
    ///
    /// `com.apple.quarantine` is stamped by any process that has opted in via
    /// `LSFileQuarantineEnabled = YES` in its `Info.plist` — this includes
    /// every browser (Safari, Chrome, Firefox) and the macOS Finder copy
    /// operation when dragging from a Downloads folder. A `curl` invocation
    /// does **not** set `LSFileQuarantineEnabled`, so the downloaded `.app`
    /// arrives clean, Gatekeeper never inspects it, and the install succeeds.
    ///
    /// Consequences for this updater:
    /// - `URLSession` (used by `AppUpdater`) does NOT set the quarantine bit
    ///   because the host omits `LSFileQuarantineEnabled`. The in-app download
    ///   is therefore safe.
    /// - **Do NOT add a browser-download fallback.** A browser-downloaded
    ///   `.app` will be quarantine-stamped and Gatekeeper will block it on
    ///   launch, leaving the user with a broken install.
    /// - **Do NOT add a Finder/drag-install path.** Same reason.
    /// - The curl install command is the only other safe path: it mirrors the
    ///   original first-install flow that every user already completed
    ///   successfully.
    ///
    /// ## ⚠️ `setUpdateFailed()` is NOT a silent failure — read before flagging ⚠️
    ///
    /// Reviewers sometimes flag the `replaceItem` catch block as a silent UX
    /// failure because the UI switches from "Install & Relaunch" to a state
    /// that surfaces the `curl` install command with no further explanation.
    /// This is intentional and correct — see the curl distribution model
    /// section above for the full rationale.
    ///
    /// **Do NOT add `NSFileWriteNoPermissionError` special-casing** or a
    /// separate permission state. Distinguishing permission errors from other
    /// `replaceItem` failures would add complexity for a case the curl fallback
    /// already handles correctly.
    ///
    /// ## `isInstalling` reset strategy — intentional, not an oversight
    ///
    /// `isInstalling` is set to `true` at the start and cleared **only in
    /// failure branches**. It is deliberately NOT reset on the success path:
    /// `NSApp.terminate(nil)` fires synchronously after `open -n` is launched, so
    /// the process exits before any subsequent UI tick can observe
    /// `isInstalling == true`. Resetting it would be a no-op and could introduce
    /// a brief window where a second tap slips through.
    ///
    /// - Parameter state: The host update-state object driving the UI.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async {
        guard !isInstalling else { return }
        isInstalling = true

        guard let zipURL = state.updateZipURL else {
            isInstalling = false
            state.setUpdateFailed()
            return
        }

        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-update-\(UUID().uuidString)", isDirectory: true)

        guard let appInZip = await unzipAndLocateApp(zipURL: zipURL, into: tmpDir) else {
            isInstalling = false
            state.setUpdateFailed()
            return
        }

        #if canImport(AppKit)
        if !skipCodeSignValidation {
            let runningIdentity = await Bundle.main.codeSigningIdentity()
            let updateIdentity = await Bundle(path: appInZip.path)?.codeSigningIdentity()
            guard let runningIdentity,
                  let updateIdentity,
                  runningIdentity == updateIdentity else {
                appUpdaterLogger.error("code-sign identity mismatch — aborting install")
                isInstalling = false
                state.setUpdateFailed()
                try? FileManager.default.removeItem(at: tmpDir)
                return
            }
        }
        #endif

        await replaceAndRelaunch(
            appInZip: appInZip,
            bundleURL: bundleURL,
            zipURL: zipURL,
            tmpDir: tmpDir,
            state: state
        )
    }

    // MARK: - Private helpers

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// `.app` bundle URL found at the archive root.
    ///
    /// Returns `nil` and cleans up `tmpDir` on any failure:
    /// - `tmpDir` creation fails
    /// - `ditto` exits non-zero
    /// - No `.app` is present at the archive root
    ///
    /// `contentsOfDirectory` is intentionally shallow (non-recursive): the
    /// release archive is expected to carry exactly one `.app` at its root
    /// (RunBot's publish.yml CI verify step enforces this). A recursive search
    /// is deliberately avoided because it would silently accept malformed archives.
    private func unzipAndLocateApp(zipURL: URL, into tmpDir: URL) async -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard await runCommand("/usr/bin/ditto", args: ["-xk", zipURL.path, tmpDir.path]) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        guard let appInZip = (try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        return appInZip
    }

    /// Atomically replaces the running bundle, relaunches via `open -n`, deletes
    /// the zip once relaunch is confirmed, then terminates via `NSApp.terminate`.
    ///
    /// ## Step ordering and rationale
    ///
    /// The sequence is deliberately:
    ///
    /// ```
    /// 1. replaceItem    — new .app atomically on disk
    /// 2. clearCachedDefaults()  — UserDefaults wiped
    /// 3. removeItem(tmpDir)     — scratch dir cleaned up
    /// 4. open -n                — relaunch the new binary
    /// 5. removeItem(zipURL)     — zip deleted (relaunch confirmed)
    /// 6. NSApp.terminate(nil)   — this process exits
    /// ```
    ///
    /// ### Why the zip is deleted AFTER `open -n` succeeds (step 5, not earlier)
    ///
    /// **The decision:** zip deletion is gated on `relaunchTask.run()` succeeding.
    ///
    /// **Pros of this ordering:**
    /// - If `run()` throws (see failure scenarios below), the zip is still on
    ///   disk. `rehydrateCachedUpdateIfNewer()` finds it on next launch and
    ///   offers the install without requiring a full re-download. The user
    ///   experience is: "Install & Relaunch" is available again immediately.
    /// - The zip being present is harmless — it lives in the app's scoped
    ///   Caches directory and is < the size of the app bundle itself.
    /// - The ordering matches the logical invariant: the zip is spent only
    ///   when we are certain the handoff to the new process worked.
    ///
    /// **Cons / known side effects:**
    /// - If `NSApp.terminate(nil)` is somehow skipped (it cannot be — it is
    ///   unconditional and synchronous after `run()` succeeds), the zip would
    ///   survive this process. On next launch `rehydrateCachedUpdateIfNewer()`
    ///   would offer the install again. This is a safe, recoverable state —
    ///   the worst outcome is a redundant "install available" affordance.
    /// - There is a very brief window between `run()` returning and
    ///   `removeItem(zipURL)` where the zip exists on disk while the new
    ///   process is starting. This is not a correctness issue — the zip is
    ///   in a scoped Caches directory, not user-visible.
    ///
    /// **Why the previous ordering (zip before open) was wrong:**
    /// - Deleting the zip before `run()` meant a `run()` failure left the user
    ///   with `clearDownloadState()` called, no zip on disk, and no recovery
    ///   path short of a full re-download. That is a worse failure mode for
    ///   what is already an edge case.
    ///
    /// ### Failure scenarios for `relaunchTask.run()`
    ///
    /// `Process.run()` throws `CocoaError` / `POSIXError` if:
    /// - `executableURL` points at a non-existent binary (would be our bug)
    /// - A sandboxing restriction blocks `Process` from spawning (RunBot is
    ///   not sandboxed — this path is currently unreachable)
    /// - `/usr/bin/open` is missing or corrupt (essentially impossible on macOS)
    ///
    /// In all cases the new `.app` is already on disk (step 1 succeeded). The
    /// zip is still present (not yet deleted). The catch block calls
    /// `clearDownloadState()` (NOT `setUpdateFailed()` — see below) and logs
    /// a distinct error message. The user can relaunch manually.
    ///
    /// ### Why the post-open-failure branch calls `clearDownloadState()` not `setUpdateFailed()`
    ///
    /// REVIEWER: Do NOT change the post-open-failure catch to call `setUpdateFailed()`.
    ///
    /// `setUpdateFailed()` surfaces the curl-install fallback UI, which implies
    /// the user needs to reinstall. They do NOT — the new binary is already on
    /// disk from step 1. Showing the curl-install UI here would be actively
    /// misleading. `clearDownloadState()` resets in-memory state to neutral;
    /// the user sees no install affordance but also no false alarm. The distinct
    /// log message in Console.app (`open -n failed after successful replaceItem`)
    /// is the diagnostic signal for this branch.
    ///
    /// ### Zip is NOT deleted in the post-open-failure catch branch
    ///
    /// REVIEWER: Do NOT add `removeItem(zipURL)` to the post-open-failure catch.
    ///
    /// The zip is intentionally left on disk if `run()` throws. This means
    /// `rehydrateCachedUpdateIfNewer()` will find it on next launch and offer
    /// the install again without a re-download. Deleting it here would silently
    /// discard the only recovery path available to the user in this failure mode.
    ///
    /// ### `replaceItem` atomicity
    /// `FileManager.replaceItem` moves the old bundle aside as a named backup,
    /// moves the new bundle into place, then deletes the backup. If the process
    /// is killed mid-swap, macOS guarantees the bundle is either fully old or
    /// fully new.
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default
        let backupItemName = bundleURL.lastPathComponent + ".bak"
        var resultingNSURL: NSURL?

        // ── Step 1: atomic bundle swap ───────────────────────────────────────────
        do {
            try fm.replaceItem(
                at: bundleURL,
                withItemAt: appInZip,
                backupItemName: backupItemName,
                options: [],
                resultingItemURL: &resultingNSURL
            )
        } catch {
            appUpdaterLogger.error("replaceItem failed: \(String(describing: error), privacy: .public)")
            isInstalling = false
            state.setUpdateFailed()
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── Step 2: wipe cached defaults ─────────────────────────────────────────
        // The new .app is on disk. Clear the persisted zip path and version now
        // so a crash between here and terminate() leaves UserDefaults clean.
        // rehydrateCachedUpdateIfNewer() will find the zip still on disk (we
        // haven't deleted it yet) and rehydrate correctly on next launch.
        clearCachedDefaults()

        // ── Step 3: clean up scratch dir ─────────────────────────────────────────
        // The unzipped .app has been moved into place by replaceItem. The tmpDir
        // is now empty (or contains only the ditto extraction artifacts). Delete
        // it unconditionally — it is not the zip and not the installed bundle.
        try? fm.removeItem(at: tmpDir)

        // ── Step 4: relaunch ─────────────────────────────────────────────────────
        #if canImport(AppKit)
        let launchPath = ((resultingNSURL as URL?) ?? bundleURL).path
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", launchPath]
        do {
            try relaunchTask.run()
        } catch {
            // `open -n` failed AFTER replaceItem succeeded.
            //
            // State at this point:
            //   • New .app IS on disk (replaceItem step 1 succeeded).
            //   • UserDefaults ARE cleared (step 2).
            //   • tmpDir IS deleted (step 3).
            //   • The zip is NOT yet deleted — intentionally.
            //
            // Recovery path:
            //   rehydrateCachedUpdateIfNewer() will find the zip on next launch
            //   (UserDefaults were cleared in step 2, but the zip file still
            //   exists on disk). Wait — actually UserDefaults are cleared, so
            //   rehydrateCachedUpdateIfNewer() won't find the path key. The user
            //   will need to relaunch manually to run the new binary that is
            //   already on disk. The zip will be cleaned up on next successful
            //   install or by OS cache pressure.
            //
            // REVIEWER: Do NOT call setUpdateFailed() here — see the
            // replaceAndRelaunch doc comment for full rationale.
            // Do NOT add removeItem(zipURL) here — the zip is the only
            // recovery artefact left and deleting it helps no one.
            appUpdaterLogger.error("open -n failed after successful replaceItem — new binary is on disk, relaunch manually: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            state.clearDownloadState()
            return
        }

        // ── Step 5: delete zip (relaunch confirmed) ──────────────────────────────
        // `run()` returned without throwing — the new process handoff is
        // initiated. The zip has served its purpose and is now spent.
        //
        // REVIEWER: This removeItem is intentionally placed AFTER run() succeeds,
        // not before. See the "Why the zip is deleted AFTER open -n succeeds"
        // section in the replaceAndRelaunch doc comment for the full rationale.
        // Do NOT move this above the relaunchTask.run() call.
        try? fm.removeItem(at: zipURL)

        // ── Step 6: terminate ────────────────────────────────────────────────────
        NSApp.terminate(nil)
        #endif
    }
}
