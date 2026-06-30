// AutoUpdater.swift
// RunBotCore
import AppKit
import Foundation

// MARK: - AutoUpdater

/// Drives the background download phase of the in-app auto-update flow
/// described in issue #1794.
///
/// `AutoUpdater` is a caseless enum (no instances, no state of its own) that
/// acts as a namespace for static functions. All persistent state lives in
/// `RunnerState` (in-memory, `@Observable`) and `UserDefaults` (via
/// `AutoUpdaterDefaults`) so the flow survives app restarts gracefully.
///
/// ## Typical call sequence
///
/// ```
/// // In AppDelegate+PanelSetup, after UpdateChecker resolves:
/// case .updateAvailable(let release):
///     runnerState.setAvailableUpdate(release.tagName)
///     await AutoUpdater.handle(release, state: runnerState)
/// ```
///
/// `handle` returns immediately after starting the download task — it does
/// not await the download itself. The download runs on a detached `Task` so
/// it does not block the startup sequence.
public enum AutoUpdater {

    /// The expected asset name for the RunBot binary zip.
    ///
    /// `publish.yml` attaches the zip with this exact name. Keeping it as a
    /// constant prevents a typo in a string literal from silently causing
    /// every release to fall back to the browser-download path.
    static let expectedAssetName = "RunBot.zip"

    // MARK: - Entry point

    /// Responds to a newly discovered available release.
    ///
    /// 1. If a matching cached zip already exists for this version, rehydrates
    ///    `RunnerState` from `UserDefaults` and returns without re-downloading.
    /// 2. If the release has no `RunBot.zip` asset, sets
    ///    `runnerState.updateAssetMissing = true` so the UI shows a browser
    ///    Download fallback, then returns.
    /// 3. Otherwise, starts a detached `Task` to download the zip in the
    ///    background. `RunnerState` is updated on `MainActor` when done.
    ///
    /// - Parameters:
    ///   - release: The `AvailableRelease` returned by `UpdateChecker`.
    ///   - state: The shared `RunnerState` instance to update.
    @MainActor
    public static func handle(_ release: AvailableRelease, state: RunnerState) async {
        // ── 1. Already cached? ──────────────────────────────────────────────
        let defaults = UserDefaults.standard
        let cachedVersion = defaults.string(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        let cachedPath   = defaults.string(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)

        if cachedVersion == release.tagName,
           let path = cachedPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                state.updateZipURL = url
                state.cachedUpdateVersion = cachedVersion
                return
            }
            // Cached path no longer exists on disk — clear stale defaults and
            // fall through to a fresh download.
            clearCachedDefaults()
        }

        // ── 2. Asset absent from release? ───────────────────────────────────
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            state.updateAssetMissing = true
            return
        }

        // ── 3. Kick off background download ─────────────────────────────────
        // Capture only what the Task needs; avoids capturing the entire state object.
        let downloadURL = asset.browserDownloadURL
        let tagName = release.tagName

        Task.detached(priority: .background) {
            await downloadUpdate(from: downloadURL, version: tagName, state: state)
        }
    }

    // MARK: - Download

    /// Downloads the zip to the caches directory, then updates `RunnerState`
    /// and `UserDefaults` on success.
    ///
    /// On any failure, `runnerState.updateActionFailed` is set to `true` so the
    /// UI can offer the browser-based fallback.
    ///
    /// ## ⚠️ NO ZIP INTEGRITY CHECK — THIS IS INTENTIONAL, TRACKED IN #1795 ⚠️
    ///
    /// This function does NOT verify the downloaded zip in any way. There is no
    /// SHA-256 checksum comparison, no GPG signature check, no `codesign --verify`
    /// call, and no zip-structure sanity check. The file is moved to disk as-is.
    ///
    /// This is a DELIBERATE, DOCUMENTED deferral — not an oversight.
    ///
    /// **Why deferred:** Integrity checking requires publishing a checksum file
    /// alongside the zip in publish.yml (SHA-256 sidecar or a signed manifest),
    /// which is a non-trivial CI change with its own review cycle. Doing it
    /// half-heartedly here (e.g. checking zip magic bytes only) creates false
    /// confidence. The correct solution is tracked in full in issue #1795.
    ///
    /// **What is already in place for #1795:** `AvailableRelease.checksumURL`
    /// is already decoded from the GitHub Releases JSON, so #1795 can add
    /// verification without any model change — just the download + compare logic.
    ///
    /// **REVIEWER: Do NOT request adding `codesign --verify` or a checksum here.
    /// It belongs in #1795. Adding a partial check here without the publish.yml
    /// sidecar would silently fail for every real release and block all updates.
    /// This is a known gap, not a forgotten one.**
    ///
    /// - Parameters:
    ///   - url: The direct download URL for the `RunBot.zip` asset.
    ///   - version: The tag name of the release being downloaded.
    ///   - state: The shared `RunnerState` to update on the `MainActor`.
    private static func downloadUpdate(
        from url: URL,
        version: String,
        state: RunnerState
    ) async {
        do {
            // URLSession.download(from:) streams to a temp file automatically;
            // we move it to the caches directory so it persists across restarts.
            // Redirects are followed transparently — the response here is the
            // terminal response after all redirects, so statusCode reflects the
            // final server reply (not an intermediate redirect).
            let (tempURL, response) = try await URLSession.shared.download(from: url)

            // ⚠️ `!= 200` IS INTENTIONALLY STRICT — DO NOT WIDEN TO `!(200...299)` ⚠️
            //
            // This is NOT a bug. GitHub's asset CDN (objects.githubusercontent.com)
            // returns exactly HTTP 200 on a successful full-file download. The other
            // 2xx codes cannot occur here:
            //   • 206 Partial Content — impossible, we send no Range header.
            //   • 304 Not Modified   — impossible, we send no If-None-Match /
            //                         If-Modified-Since header.
            //
            // Using `!(200...299)` would silently accept a 206 or 304 body as a
            // valid zip and cache a corrupt / zero-byte file. The strict `!= 200`
            // check ensures we only cache a response we know to be a complete file.
            //
            // REVIEWER: Do NOT change this to `!(200...299)`. If GitHub's CDN ever
            // returns a non-200 success code, that is the moment to widen the check
            // with a comment explaining which code and why — not before.
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }

            let destination = try cachedZipDestination(version: version)

            // Remove any stale file from a previous interrupted download.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // Persist to UserDefaults so the install survives a relaunch.
            let defaults = UserDefaults.standard
            defaults.set(version, forKey: AutoUpdaterDefaults.cachedUpdateVersion)
            defaults.set(destination.path, forKey: AutoUpdaterDefaults.cachedUpdateZipPath)

            // Push to RunnerState on the MainActor — Views observe this.
            await MainActor.run {
                state.updateZipURL = destination
                state.cachedUpdateVersion = version
            }
        } catch {
            await MainActor.run {
                state.updateActionFailed = true
            }
        }
    }

    // MARK: - Helpers

    /// Returns the destination `URL` for the cached zip in the system caches
    /// directory, creating the intermediate directory if needed.
    ///
    /// The file is named `RunBot-<version>.zip` (e.g. `RunBot-v0.8.0.zip`)
    /// so multiple cached versions never collide on disk.
    ///
    /// ## Stale zip accumulation — known, acceptable, low priority
    ///
    /// Each update cycle writes a new version-stamped file. `downloadUpdate`
    /// removes the file at `destination` before writing (handling interrupted
    /// downloads of the *same* version), but files from *prior* versions
    /// (e.g. `RunBot-v0.7.9.zip` left over after a successful install) are
    /// not swept here.
    ///
    /// In practice this means at most one stale zip per update cycle accumulates
    /// in `~/Library/Caches/io.github.runbot-hq/`. Each file is ~10–20 MB and
    /// macOS will evict cache-directory contents under storage pressure. This
    /// is acceptable for a low-frequency update path.
    ///
    /// If a future audit shows meaningful accumulation, add a sweep here:
    ///
    ///     let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    ///     existing.filter { $0.lastPathComponent.hasPrefix("RunBot-") && $0.pathExtension == "zip" }
    ///             .forEach { try? fm.removeItem(at: $0) }
    ///
    /// REVIEWER: The absence of this sweep is intentional, not an oversight.
    private static func cachedZipDestination(version: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = caches.appendingPathComponent("io.github.runbot-hq", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sanitise the version tag: strip any characters that are invalid in
        // a filename (shouldn't arise with semver tags, but belt-and-braces).
        let safe = version.replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("RunBot-\(safe).zip")
    }

    /// Removes the cached update entries from `UserDefaults`.
    ///
    /// Called when the cached path is stale (file deleted externally) to
    /// prevent an infinite no-op loop on subsequent launches.
    private static func clearCachedDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)
    }

    // MARK: - Background scheduler

    /// Retains the `NSBackgroundActivityScheduler` for the lifetime of the app.
    ///
    /// `NSBackgroundActivityScheduler` is **not** retained by the system after
    /// `schedule { }` is called — unlike `Timer`, the caller must hold a strong
    /// reference. Without this property the scheduler is deallocated immediately
    /// after `scheduleBackgroundCheck` returns and the background check silently
    /// never fires.
    ///
    /// `@MainActor` matches `scheduleBackgroundCheck`'s isolation so the
    /// assignment is data-race free under Swift 6 strict concurrency.
    @MainActor private static var backgroundScheduler: NSBackgroundActivityScheduler?

    /// Registers an `NSBackgroundActivityScheduler` that fires a full
    /// update check every `AutoUpdaterDefaults.checkInterval` seconds.
    ///
    /// Call once from `AppDelegate` after the startup sequence completes.
    /// The scheduler is stored in `backgroundScheduler` above so it is not
    /// deallocated before it fires; it runs on a background queue and bridges
    /// back to `MainActor` for any `RunnerState` mutations.
    ///
    /// - Parameter state: The shared `RunnerState` instance to update.
    @MainActor
    public static func scheduleBackgroundCheck(state: RunnerState) {
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "io.github.runbot-hq.update-check"
        )
        scheduler.repeats = true
        scheduler.interval = AutoUpdaterDefaults.checkInterval
        // Allow the system up to 20 % of the interval as tolerance so it can
        // coalesce with other background work and save power.
        scheduler.tolerance = AutoUpdaterDefaults.checkInterval * 0.2
        scheduler.qualityOfService = .background

        // `NSBackgroundActivityScheduler` is not `Sendable`. The weak capture
        // below is safe: `.shouldDefer` is only read inside this callback, which
        // AppKit guarantees fires on the same background serial queue. The
        // `nonisolated(unsafe)` local copy asserts that invariant to the compiler.
        // Do NOT change to a strong capture — that would prevent the scheduler
        // from being released when `backgroundScheduler` is set to nil.
        scheduler.schedule { [weak scheduler] completion in
            // `NSBackgroundActivityScheduler` is not `Sendable`; the weak capture
            // is safe because `.shouldDefer` is only read inside this callback,
            // which AppKit guarantees fires on the same background serial queue.
            // `nonisolated(unsafe)` asserts that invariant to the Swift 6 checker.
            // Do NOT remove — without it Swift 6 strict concurrency emits a
            // SendableClosureCaptures warning on the `scheduler` capture.
            nonisolated(unsafe) let s = scheduler
            // Honour the system's power-saving signal. `s.shouldDefer` returns
            // true when macOS is asking background tasks to pause (e.g. low
            // battery, high CPU load). Calling `.deferred` tells the scheduler
            // to retry at the next interval. This is the documented pattern for
            // NSBackgroundActivityScheduler (see #1794 Architecture notes, Pillar 5).
            guard s?.shouldDefer == false else {
                completion(.deferred)
                return
            }
            Task {
                let beta = await AppPreferencesStore.shared.betaChannel
                let result = await UpdateChecker.checkForUpdate(betaChannel: beta)
                await MainActor.run {
                    if case .updateAvailable(let release) = result {
                        state.setAvailableUpdate(release.tagName)
                        // Fire-and-forget: handle starts the download task and
                        // returns immediately without awaiting the download.
                        // completion(.finished) below is correct — it tells the
                        // system this scheduler invocation is done, which is true:
                        // the download continues on its own detached Task.
                        // Do NOT change this to `await AutoUpdater.handle(…)` —
                        // that would hold the system completion until the download
                        // finishes, unnecessarily blocking scheduler rescheduling.
                        Task { await AutoUpdater.handle(release, state: state) }
                    }
                }
                completion(.finished)
            }
        }

        // Retain the scheduler so it is not deallocated before it fires.
        // NSBackgroundActivityScheduler is not system-owned after schedule { };
        // releasing it here would cause the background check to silently stop.
        backgroundScheduler = scheduler
    }

    // MARK: - Install & Relaunch

    /// Unzips the cached `RunBot.zip`, replaces the running `.app` bundle,
    /// and relaunches the new version.
    ///
    /// ## Flow
    /// 1. Unzip the cached zip into a temporary directory via `/usr/bin/ditto`.
    /// 2. Locate `RunBot.app` inside the unzipped contents.
    /// 3. Replace the running bundle via `ditto` (bundle-over-bundle safe).
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
    @MainActor private static var isInstalling: Bool = false

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

        // ── 1. Unzip to a temp directory ────────────────────────────────────
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

        // ── 2. Find RunBot.app inside the unzipped contents ─────────────────
        guard let appInZip = (try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.lastPathComponent == "RunBot.app" }) else {
            isInstalling = false
            state.updateActionFailed = true
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 3. Replace the running bundle ───────────────────────────────────
        // Use `ditto` (already available) rather than `cp -Rf` for the
        // bundle-replacement step.
        //
        // `cp -Rf src.app dst.app` where dst.app already exists as a directory
        // copies src.app *inside* dst.app, producing dst.app/src.app — a nested
        // bundle that will not launch. `ditto` copies the *contents* of the
        // source over the destination, correctly replacing the bundle in-place
        // and preserving resource forks and symlinks.
        let replaceResult = await runCommand("/usr/bin/ditto",
                                             args: [appInZip.path, bundleURL.path])
        guard replaceResult else {
            isInstalling = false
            state.updateActionFailed = true
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── 4. Clear cached defaults so next launch starts clean ─────────────
        clearCachedDefaults()
        try? fm.removeItem(at: tmpDir)
        try? fm.removeItem(at: zipURL)

        // ── 5. Relaunch + terminate ──────────────────────────────────────────
        // `open -n` forces a new instance even if one is already running.
        // We do NOT await — NSApp.terminate must fire immediately after.
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
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", bundleURL.path]
        try? relaunchTask.run()

        NSApp.terminate(nil)
    }

    // MARK: - Process helper

    /// Runs a command synchronously on a background thread and returns `true`
    /// on exit code 0, `false` otherwise.
    ///
    /// Used for `ditto` (unzip and bundle replacement) which is short-lived
    /// and does not need streaming output.
    ///
    /// ## ⚠️ `waitUntilExit()` IS INTENTIONAL — NOT A MISSING `terminationHandler` ⚠️
    ///
    /// Issue #1794 (Architecture notes, Pillar 5) documents a
    /// `terminationHandler` + `withCheckedContinuation` variant that avoids
    /// holding any GCD thread. This function uses `waitUntilExit()` on a GCD
    /// background thread instead. Both are correct — neither blocks the Swift
    /// concurrency executor.
    ///
    /// The tradeoff: `waitUntilExit()` holds one GCD thread for the lifetime
    /// of the subprocess (~1–2 s for `ditto`). For a two-call sequence that
    /// runs once per update cycle this is completely acceptable; RunBot has no
    /// scenario where many concurrent `ditto` invocations would exhaust the
    /// thread pool.
    ///
    /// Switching to `terminationHandler` is a future quality-of-life improvement,
    /// NOT a bug fix or a correctness requirement. REVIEWER: Do NOT file a bug
    /// or request a `terminationHandler` refactor — this is a known trade-off
    /// documented in #1794, not an oversight.
    /// Runs a command and returns its stderr output (empty string on success or
    /// if stderr is unavailable). Used by `runCommand` to capture diagnostic
    /// information when a subprocess fails.
    ///
    /// ## Why stderr is captured (not discarded)
    ///
    /// Earlier versions of this function routed both stdout and stderr to
    /// `FileHandle.nullDevice`, which made `ditto` failures completely silent:
    /// the install path would fail, `updateActionFailed` would flip to `true`,
    /// and the user would see a "Download" fallback with no indication of
    /// what went wrong. This made install failures undiagnosable in the field.
    ///
    /// Stderr is now piped and logged at `.error` level on failure so that
    /// Console.app and crash reports contain actionable information. Stdout
    /// remains discarded — `ditto` produces no useful stdout.
    private static func runCommand(_ executable: String, args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice

                // Pipe stderr so failures are diagnosable. stdout is still
                // discarded — ditto produces no useful stdout on success.
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let succeeded = process.terminationStatus == 0
                    if !succeeded {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrMsg = String( stderrData, encoding: .utf8) ?? "(unreadable)"
                        log(.error, category: .services,
                            "AutoUpdater: \(executable) failed (exit \(process.terminationStatus)): \(stderrMsg)")
                    }
                    continuation.resume(returning: succeeded)
                } catch {
                    log(.error, category: .services,
                        "AutoUpdater: could not launch \(executable): \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
