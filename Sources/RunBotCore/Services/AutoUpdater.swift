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
    /// ## Integrity verification — v1 status
    ///
    /// **No integrity check is performed in v1.** The zip is moved to the
    /// caches directory as-is, without any verification.
    ///
    /// Both SHA-256 checksum verification and code-signing identity verification
    /// (`codesign --verify`) are **fully deferred to issue #1795**. Neither is
    /// present in this function. `AvailableRelease.checksumURL` is already
    /// decoded so #1795 can add verification logic without a model change.
    ///
    /// Do not add a `codesign --verify` call here, and do not claim integrity
    /// verification anywhere in the UI or docs, until #1795 is implemented.
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

            // `!= 200` is intentionally strict here — not `!(200...299)`.
            //
            // GitHub's asset download URLs (objects.githubusercontent.com) always
            // return 200 on success. 206 Partial Content cannot occur because we
            // send no Range header. 304 Not Modified cannot occur because we send
            // no If-None-Match / If-Modified-Since header. Widening to 200...299
            // would silently cache a partial or unmodified response as a valid
            // zip — a stricter check is safer here.
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

        scheduler.schedule { [weak scheduler] completion in
            // Honour the system's power-saving signal. `scheduler.shouldDefer`
            // returns true when macOS is asking background tasks to pause (e.g.
            // low battery, high CPU load). Calling `.deferred` tells the scheduler
            // to try again at the next interval rather than proceeding now. This is
            // the documented pattern for NSBackgroundActivityScheduler (see #1794
            // Architecture notes, Pillar 5).
            // Note: `shouldDefer` is a property on the *scheduler*, not on the
            // `completion` handler — the handler is just a `(Result) -> Void`.
            // Weak capture avoids retaining the scheduler beyond its intended
            // lifetime; if it has been deallocated, treat as deferred.
            guard scheduler?.shouldDefer == false else {
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
    /// Double-tap guard — `@MainActor`-isolated so access is data-race free under
    /// Swift 6 strict concurrency. Set to `true` before install begins; cleared
    /// only in the failure path. On success `NSApp.terminate` fires immediately
    /// so the flag never needs resetting.
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
        // NSApp.terminate(nil) is used here rather than exit(0) deliberately.
        // exit(0) is the helper-process self-update pattern; RunBot is a full
        // AppKit app with no applicationWillTerminate side-effects that conflict
        // with the handoff. NSApp.terminate is the idiomatic shutdown path.
        // This decision is documented in the "Why NSApp.terminate" section of
        // installAndRelaunch's doc comment and in issue #1794. Do not change
        // this to exit(0) without revisiting #1794.
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
    /// ## Why `waitUntilExit()` on a GCD thread (not `terminationHandler`)
    ///
    /// The spec (issue #1794, Architecture notes, Pillar 5) describes a
    /// `terminationHandler` + `withCheckedContinuation` pattern that avoids
    /// any blocking call. This implementation dispatches to a GCD background
    /// thread and calls `waitUntilExit()` there instead. Both patterns keep
    /// the Swift executor free — the difference is that `waitUntilExit()` holds
    /// one GCD thread for the duration of `ditto`'s run (~1–2 s). For this
    /// use-case the practical impact is negligible. Refactoring to
    /// `terminationHandler` is a future improvement, not a correctness fix.
    private static func runCommand(_ executable: String, args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError  = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
