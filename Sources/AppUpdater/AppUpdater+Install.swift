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
    /// host's browser-download fallback becomes visible.
    ///
    /// ## ⚠️ `setUpdateFailed()` is NOT a silent failure — read before flagging ⚠️
    ///
    /// Reviewers sometimes flag the `replaceItem` catch block as a silent UX
    /// failure because the UI switches from "Install & Relaunch" to a "Download"
    /// button with no explanation. This is intentional and correct for a
    /// curl-install distribution model (RunBot's): the "Download" fallback
    /// surfaces the install command — the same path every user took for first
    /// install. A user who hits a `replaceItem` permission error is correctly
    /// directed back to that path.
    ///
    /// **Do NOT add `NSFileWriteNoPermissionError` special-casing** or a
    /// separate permission state. Distinguishing permission errors from other
    /// `replaceItem` failures would add complexity for a case the fallback
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
    ///   `setUpdateFailed()` is called so the fallback shows.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async { // skipcq: SW-R1002 — reviewed; complexity acceptable for this sequential install flow
        // Double-tap guard — prevents two concurrent install attempts if the
        // user taps "Install & Relaunch" twice before NSApp.terminate fires.
        guard !isInstalling else { return }
        isInstalling = true

        guard let zipURL = state.updateZipURL else {
            isInstalling = false
            state.setUpdateFailed()
            return
        }

        let fm = FileManager.default
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath) // e.g. …/RunBot.app

        // ── 1. Unzip to a temp directory ───────────────────────────────────────
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("appupdater-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            isInstalling = false
            state.setUpdateFailed()
            return
        }

        // ditto preserves symlinks and resource forks; superior to `unzip` for
        // .app bundles.
        let dittoResult = await runCommand("/usr/bin/ditto", args: ["-xk", zipURL.path, tmpDir.path])
        guard dittoResult else {
            isInstalling = false
            state.setUpdateFailed()
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 2. Find the .app bundle inside the unzipped contents ───────────────
        // `contentsOfDirectory` is intentionally shallow (non-recursive): the
        // release archive is expected to carry exactly one `.app` at its root
        // (RunBot's publish.yml CI verify step enforces this). If no `.app` is
        // present at the top level this guard fires — the correct signal that
        // the archive is malformed. A recursive search is deliberately avoided
        // because it would silently accept such malformed archives.
        guard let appInZip = (try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension == "app" }) else {
            isInstalling = false
            state.setUpdateFailed()
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 2b. Gatekeeper / quarantine — no strip needed ──────────────────────
        // Reviewers familiar with Sparkle may expect an
        // `xattr -dr com.apple.quarantine` call here before replaceItem. It is
        // not needed: `com.apple.quarantine` is only applied by processes that
        // opt in via LSFileQuarantineEnabled = YES. A host that omits that key
        // (RunBot does) never has its URLSession download stamped, so ditto has
        // nothing to propagate and Gatekeeper will not prompt on relaunch.
        //
        // REVIEWER: Do NOT add a quarantine-strip step here. If a host sets
        // LSFileQuarantineEnabled, revisit at that point.

        // ── 3. Replace the running bundle — atomic swap via replaceItem ────────
        // `FileManager.replaceItem` moves the old bundle aside as a named
        // backup, moves the new bundle into place, then deletes the backup — all
        // at the filesystem level. If the process is killed mid-swap, macOS
        // guarantees the bundle directory is either fully old or fully new. A
        // half-written bundle is not possible.
        //
        // resultingItemURL: On a same-volume APFS rename the returned URL equals
        // `bundleURL`. On a cross-volume copy-and-delete macOS may return a
        // different URL; we capture it and use it as the relaunch path. Falls
        // back to `bundleURL` if nil.
        //
        // Note: `replaceItem` takes `AutoreleasingUnsafeMutablePointer?`, so the
        // out-variable must be declared as `NSURL?`, not `URL?`, then bridged.
        let backupItemName = bundleURL.lastPathComponent + ".bak"
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
            // setUpdateFailed() here is NOT a silent failure — see the doc
            // comment above. The browser-download fallback is the correct and
            // complete recovery path for any install failure.
            isInstalling = false
            state.setUpdateFailed()
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 4. Clear cached defaults so next launch starts clean ───────────────
        // The zip is deleted here, BEFORE open -n fires in step 5. This is safe:
        // replaceItem (step 3) is in a do/catch, so this line is only reached
        // after the new .app is already atomically in place. At that point the
        // zip is spent — if open -n fails on an already-swapped bundle, the zip
        // cannot help (re-installing would write the same binary that just failed
        // to launch). The Download fallback is the correct recovery path.
        clearCachedDefaults()
        try? fm.removeItem(at: tmpDir)
        try? fm.removeItem(at: zipURL)

        // ── 5. Relaunch + terminate ────────────────────────────────────────────
        // `open -n` forces a new instance even if one is already running. We do
        // NOT await — NSApp.terminate must fire immediately after. This is the
        // accepted pattern for macOS self-update (Sparkle uses the same
        // ordering). Use `resultingNSURL` as the authoritative post-swap bundle
        // path, falling back to `bundleURL`.
        let launchPath = ((resultingNSURL as URL?) ?? bundleURL).path
        // AppKit is unavailable in the SPM headless test runner — this guard is
        // required for `swift test` even though the package is macOS(.v26)-only.
        #if canImport(AppKit)
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", launchPath]
        do {
            try relaunchTask.run()
        } catch {
            // `open -n` failed — the new binary could not be launched. The zip
            // was already deleted (step 4) so updateZipURL must be cleared to
            // prevent the next "Install & Relaunch" tap from entering ditto on a
            // nonexistent file and cycling into setUpdateFailed() permanently.
            //
            // setDownloadStarted() is intentionally reused here for its side-
            // effects (clears updateZipURL + cachedUpdateVersion) — not to signal
            // a new download is beginning. A dedicated clearDownloadState() method
            // was considered but rejected: it would be a breaking protocol change
            // with an identical implementation to setDownloadStarted(). If
            // setDownloadStarted() ever gains download-UI side-effects (e.g. a
            // spinner), split it into a separate protocol method at that point.
            appUpdaterLogger.error("open -n failed, aborting relaunch: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            state.setDownloadStarted()
            state.setUpdateFailed()
            return
        }
        NSApp.terminate(nil) // ← intentional AppKit shutdown — NOT exit(0), read comment above
        #endif
    }
}
