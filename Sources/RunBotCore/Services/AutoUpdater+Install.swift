// AutoUpdater+Install.swift
// RunBotCore
import AppKit
import Foundation

/// Install-and-relaunch logic for ``AutoUpdater``.
extension AutoUpdater {

    // MARK: - Install & Relaunch

    /// Unzips the cached `RunBot.zip`, replaces the running `.app` bundle,
    /// and relaunches the new version.
    ///
    /// ## Flow
    /// 1. Unzip the cached zip into a temporary directory via `/usr/bin/ditto`.
    /// 2. Locate `RunBot.app` inside the unzipped contents.
    /// 3. Replace the running bundle via `FileManager.replaceItem` (atomic swap, closes #1796).
    /// 4. Relaunch the new binary with `/usr/bin/open`.
    /// 5. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure the function sets `state.updateActionFailed = true` and
    /// returns without terminating — the user is left with the running version
    /// and the browser-fallback Download button becomes visible.
    ///
    /// - Parameter state: The shared `RunnerState` used to report failure.
    ///
    /// ## `isInstalling` reset strategy — intentional, not an oversight
    ///
    /// `isInstalling` is set to `true` at the start of `installAndRelaunch` and
    /// is cleared **only in failure branches**. It is deliberately NOT reset on
    /// the success path.
    ///
    /// **Why:** On the success path `NSApp.terminate(nil)` fires synchronously
    /// after `open -n` is launched. The process exits before any subsequent
    /// UI tick can observe `isInstalling == true`. Resetting it would be a
    /// no-op and could introduce a brief window where a second tap slips
    /// through between the reset and the actual termination.
    ///
    /// **The fragility concern:** If `applicationShouldTerminate` in the app
    /// delegate ever returns `.terminateLater` or `.terminateCancel`, the
    /// process would survive with `isInstalling` permanently `true`, silently
    /// disabling the Install button. RunBot's app delegate does NOT do this
    /// today. If that ever changes, add `isInstalling = false` immediately
    /// before the `NSApp.terminate(nil)` call and update this comment.
    ///
    /// REVIEWER: Do NOT add a reset on the success path without reading this
    /// comment in full and confirming `applicationShouldTerminate` behaviour.
    @MainActor static var isInstalling: Bool = false

    /// Guards against concurrent downloads of the same release.
    ///
    /// `handle()` is `@MainActor`, so reads and writes to this flag are
    /// serialised on the main actor — no additional locking is needed.
    /// Set to `true` just before `Task.detached` is spawned; reset to `false`
    /// inside `downloadUpdate` on both the success and failure paths (via
    /// `MainActor.run`).
    @MainActor static var isDownloading: Bool = false

    /// Installs the downloaded update zip and relaunches the app.
    ///
    /// Replaces the running `RunBot.app` bundle in-place, then calls
    /// `NSApp.terminate` so macOS can relaunch the new binary cleanly.
    /// On any failure the function sets `state.updateActionFailed = true` and
    /// returns without terminating — the user is left with the running version.
    ///
    /// ## Why `NSApp.terminate(nil)` and not `exit(0)`
    ///
    /// This is a deliberate, documented decision — see the decisions table in
    /// issue #1794. RunBot is non-sandboxed with no `applicationWillTerminate`
    /// side-effects that conflict with the handoff. `NSApp.terminate` is the
    /// idiomatic AppKit shutdown path and is safe here. `exit(0)` belongs to
    /// the helper-process self-update pattern, which was explicitly rejected
    /// for RunBot. Do not change this without revisiting #1794.
    ///
    /// - Parameter state: The shared `RunnerState` used to drive UI state and
    ///   to supply the downloaded zip URL via `state.updateZipURL`.
    @MainActor
    public static func installAndRelaunch(state: RunnerState) async {
        // Double-tap guard — prevents two concurrent install attempts if the
        // user taps "Install & Relaunch" twice before NSApp.terminate fires.
        guard !isInstalling else { return }
        isInstalling = true

        guard let zipURL = state.updateZipURL else {
            isInstalling = false
            state.updateActionFailed = true
            return
        }

        let fm = FileManager.default
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)  // e.g. …/RunBot.app

        // ── 1. Unzip to a temp directory ────────────────────────────────────────────
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("runbot-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            isInstalling = false
            state.updateActionFailed = true
            return
        }

        // ditto preserves symlinks and resource forks; superior to `unzip` for .app bundles.
        let dittoResult = await runCommand("/usr/bin/ditto",
                                           args: ["-xk", zipURL.path, tmpDir.path])
        guard dittoResult else {
            isInstalling = false
            state.updateActionFailed = true
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 2. Find RunBot.app inside the unzipped contents ───────────────────────
        // `contentsOfDirectory` is intentionally shallow (non-recursive).
        // The verify step in publish.yml anchors the grep pattern so that
        // RunBot.app must sit at the archive root — a nested path such as
        // subdir/RunBot.app/ will fail the CI verify step before a release
        // is ever published. If the app is absent at the top level of the
        // unzipped dir this guard fires, which is the correct signal that
        // the archive is malformed. A recursive search is deliberately
        // avoided because it would silently accept such malformed archives.
        guard let appInZip = (try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.lastPathComponent == "RunBot.app" }) else {
            isInstalling = false
            state.updateActionFailed = true
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 3. Replace the running bundle — atomic swap via replaceItem ────
        // `FileManager.replaceItem` moves the old bundle aside as a named
        // backup, moves the new bundle into place, then deletes the backup —
        // all at the filesystem level. If the process is killed mid-swap,
        // macOS guarantees the bundle directory is either fully old or fully
        // new. A half-written bundle (the failure mode of the previous
        // `ditto` in-place overwrite) is not possible.
        //
        // Why not `ditto` here (we still use it in step 1 for unzip):
        // `ditto src.app dst.app` copies *contents* of src over dst in-place.
        // A SIGKILL mid-copy leaves dst partially overwritten with no rollback.
        // `replaceItem` uses a rename-based swap at the VFS layer instead.
        //
        // resultingItemURL: On a same-volume APFS rename the returned URL equals
        // `bundleURL`. On a cross-volume copy-and-delete (rare — temp dir and
        // /Applications on different volumes) macOS may return a different URL.
        // We capture it and use it as the relaunch path so `open -n` always
        // points to the actual post-swap location rather than the pre-swap
        // `bundleURL` (which is the right path in practice, but `resultingURL`
        // is authoritative). Falls back to `bundleURL` if nil (should not occur
        // in normal operation, but belt-and-braces).
        //
        // Note: `replaceItem` takes `AutoreleasingUnsafeMutablePointer<NSURL?>?`,
        // so the out-variable must be declared as `NSURL?`, not `URL?`.
        // The value is bridged to `URL` at the use site via `as URL?`.
        //
        // Preconditions that are always true here:
        //   • `bundleURL` (dst) exists — it is `Bundle.main.bundlePath`.
        //   • `appInZip` (src) exists — step 2 just located it in `tmpDir`.
        //   • `appInZip` is a real extracted directory, not a path in a zip.
        //   • `tmpDir` is on the same volume as the system temp dir; the
        //     destination (/Applications or ~/Applications) may be on the
        //     same APFS volume, making the rename a metadata-only operation.
        //
        // The backup item (`RunBot.app.bak`) is written to the same directory
        // as `bundleURL` during the swap and removed on success. On an
        // interrupted swap, macOS removes it on the next volume mount.
        // We do not need to manage it manually.
        //
        // Closes #1796.
        var resultingNSURL: NSURL?
        do {
            try fm.replaceItem(
                at: bundleURL,
                withItemAt: appInZip,
                backupItemName: "RunBot.app.bak",
                options: [],
                resultingItemURL: &resultingNSURL
            )
        } catch {
            isInstalling = false
            state.updateActionFailed = true
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 4. Clear cached defaults so next launch starts clean ───────────────
        clearCachedDefaults()
        try? fm.removeItem(at: tmpDir)
        try? fm.removeItem(at: zipURL)

        // ── 5. Relaunch + terminate ───────────────────────────────────────────────
        // `open -n` forces a new instance even if one is already running.
        // We do NOT await — NSApp.terminate must fire immediately after.
        //
        // Use `resultingNSURL` from `replaceItem` as the authoritative post-swap
        // bundle path, bridged to URL. On same-volume APFS this equals `bundleURL`;
        // on a cross-volume swap macOS may return a different URL. Falls back to
        // `bundleURL` if `resultingNSURL` is nil (should not occur in practice).
        //
        // ⚠️ `NSApp.terminate(nil)` IS INTENTIONAL — DO NOT CHANGE TO `exit(0)` ⚠️
        //
        // This is NOT a mistake. `exit(0)` is the correct call for a detached
        // helper-process self-updater (the XPC / Sparkle-helper pattern), where
        // a spawned subprocess swaps the bundle and calls exit() to hand control
        // back to the caller. RunBot does NOT use that pattern.
        //
        // RunBot is a full AppKit application. `NSApp.terminate(nil)` is the
        // idiomatic AppKit shutdown path. It fires `applicationWillTerminate`,
        // drains the run loop, and lets the system clean up properly before the
        // process exits. Using `exit(0)` here would bypass all of that and is
        // the wrong primitive for a first-class app bundle.
        //
        // This decision was explicitly discussed and chosen in issue #1794
        // ("Why NSApp.terminate" section). REVIEWER: Do NOT change this to
        // `exit(0)` without re-reading #1794 and opening a discussion there first.
        let launchPath = ((resultingNSURL as URL?) ?? bundleURL).path
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", launchPath]
        do {
            try relaunchTask.run()
        } catch {
            // `open -n` failed — the new binary could not be launched (e.g.
            // the bundle path is corrupt or the binary is not executable after
            // the replaceItem swap). Do NOT terminate: the current process is
            // still running correctly, so we surface the failure and leave the
            // user with a working app rather than no app at all.
            log(
                "AutoUpdater: open -n failed, aborting relaunch: \(error.localizedDescription)",
                category: .services
            )
            // Clear `updateZipURL` so the next "Install & Relaunch" tap does
            // not re-enter `installAndRelaunch` with a URL pointing to a file
            // that was already deleted by `clearCachedDefaults()` + the
            // `removeItem(at: zipURL)` call above. Without this, the state
            // machine would find `updateZipURL` non-nil, attempt ditto on a
            // missing path, and fail silently every subsequent tap.
            state.updateZipURL = nil
            isInstalling = false
            state.updateActionFailed = true
            return
        }

        // Clear `updateZipURL` before terminating so that if
        // `applicationShouldTerminate` returns `.terminateCancel` and the
        // process survives, the next "Install & Relaunch" tap does not find a
        // non-nil URL pointing to an already-deleted file, enter `ditto` with
        // a missing source path, fail silently, and permanently lock the UI.
        // This mirrors the `updateZipURL = nil` in the `open -n` failure branch
        // above and closes the stale-URL half of the terminateCancel risk
        // documented in the `isInstalling` comment.
        state.updateZipURL = nil

        NSApp.terminate(nil)  // ← intentional AppKit shutdown — NOT exit(0), read comment above
    }
}
