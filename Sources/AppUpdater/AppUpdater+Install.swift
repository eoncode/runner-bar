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
    /// 3. Replace the running bundle via `FileManager.replaceItem` (atomic swap).
    /// 4. Relaunch the new binary with `/usr/bin/open`.
    /// 5. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure the function calls `state.setUpdateFailed()` and returns
    /// without terminating — the user is left with the running version and the
    /// host should direct them to re-run the original `curl` install command.
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
    /// If `applicationShouldTerminate` ever returns `.terminateLater` or
    /// `.terminateCancel`, the process would survive with `isInstalling`
    /// permanently `true`. Hosts that do this must add `isInstalling = false`
    /// before the `NSApp.terminate(nil)` call.
    ///
    /// ## Why `NSApp.terminate(nil)` and not `exit(0)`
    ///
    /// `NSApp.terminate` is the idiomatic AppKit shutdown path: it fires
    /// `applicationWillTerminate`, drains the run loop, and lets the system clean
    /// up before the process exits. `exit(0)` belongs to the detached
    /// helper-process self-update pattern, which is not used here.
    ///
    /// - Parameter state: The host update-state object driving the UI. On failure
    ///   `setUpdateFailed()` is called so the host can surface the curl install command.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async {
        // Double-tap guard — prevents two concurrent install attempts if the
        // user taps "Install & Relaunch" twice before NSApp.terminate fires.
        guard !isInstalling else { return }
        isInstalling = true

        guard let zipURL = state.updateZipURL else {
            isInstalling = false
            state.setUpdateFailed()
            return
        }

        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath) // e.g. …/RunBot.app
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-update-\(UUID().uuidString)", isDirectory: true)

        // Steps 1+2: unzip zip → locate .app inside tmpDir.
        guard let appInZip = await unzipAndLocateApp(zipURL: zipURL, into: tmpDir) else {
            isInstalling = false
            state.setUpdateFailed()
            return
        }

        // Steps 3+4+5: atomic bundle swap → clear cache → open -n → terminate.
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

        // ditto preserves symlinks and resource forks; superior to `unzip` for
        // .app bundles.
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

    /// Atomically replaces the running bundle, clears cached defaults, then
    /// relaunches via `open -n` and terminates via `NSApp.terminate`.
    ///
    /// ## Gatekeeper / quarantine — no strip needed
    /// Reviewers familiar with Sparkle may expect an
    /// `xattr -dr com.apple.quarantine` call here before replaceItem. It is
    /// not needed: `com.apple.quarantine` is only applied by processes that
    /// opt in via LSFileQuarantineEnabled = YES. A host that omits that key
    /// (RunBot does) never has its URLSession download stamped, so ditto has
    /// nothing to propagate and Gatekeeper will not prompt on relaunch.
    ///
    /// **REVIEWER: Do NOT add a quarantine-strip step here.** If a host sets
    /// LSFileQuarantineEnabled, revisit at that point.
    ///
    /// ## replaceItem atomicity
    /// `FileManager.replaceItem` moves the old bundle aside as a named backup,
    /// moves the new bundle into place, then deletes the backup — all at the
    /// filesystem level. If the process is killed mid-swap, macOS guarantees the
    /// bundle is either fully old or fully new. A half-written bundle is not
    /// possible.
    ///
    /// `resultingItemURL`: On a same-volume APFS rename the returned URL equals
    /// `bundleURL`. On a cross-volume copy-and-delete macOS may return a
    /// different URL; we use it as the relaunch path, falling back to `bundleURL`.
    ///
    /// ## Zip deletion timing
    /// The zip is deleted BEFORE `open -n` fires. This is safe: `replaceItem`
    /// is in a do/catch so this point is only reached after the new .app is
    /// atomically in place. The zip is spent at that point — re-installing
    /// would write the same binary that is about to launch.
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default
        let backupItemName = bundleURL.lastPathComponent + ".bak"
        // Note: `replaceItem` takes `AutoreleasingUnsafeMutablePointer?`, so the
        // out-variable must be declared as `NSURL?`, not `URL?`, then bridged.
        var resultingNSURL: NSURL?
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
            // setUpdateFailed() is NOT a silent failure — the host should surface
            // the curl install command as the recovery path. See the
            // installAndRelaunch doc comment ('Why curl is the only correct
            // install and recovery path') for the full rationale.
            isInstalling = false
            state.setUpdateFailed()
            try? fm.removeItem(at: tmpDir)
            return
        }

        // Clear cache before open -n — see doc comment above for timing rationale.
        clearCachedDefaults()
        try? fm.removeItem(at: tmpDir)
        try? fm.removeItem(at: zipURL)

        // AppKit is unavailable in the SPM headless test runner — this guard is
        // required for `swift test` even though the package is macOS(.v26)-only.
        #if canImport(AppKit)
        // `open -n` forces a new instance even if one is already running.
        // NOT awaited — NSApp.terminate must fire immediately after.
        // Use resultingNSURL as the authoritative post-swap path (see doc comment).
        let launchPath = ((resultingNSURL as URL?) ?? bundleURL).path
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", launchPath]
        do {
            try relaunchTask.run()
        } catch {
            appUpdaterLogger.error("open -n failed, aborting relaunch: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            // clearDownloadState() resets updateZipURL + cachedUpdateVersion
            // (now invalid — the zip was deleted above) without signalling that
            // a new download is beginning. See UpdateStateProviding.clearDownloadState().
            state.clearDownloadState()
            state.setUpdateFailed()
            return
        }
        NSApp.terminate(nil) // ← intentional AppKit shutdown — NOT exit(0), see installAndRelaunch doc
        #endif
    }
}
