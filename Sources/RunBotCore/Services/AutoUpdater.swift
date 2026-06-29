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
            let (tempURL, response) = try await URLSession.shared.download(from: url)

            // Treat non-200 as a failure rather than silently caching a bad file.
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
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

    /// Registers an `NSBackgroundActivityScheduler` that fires a full
    /// update check every `AutoUpdaterDefaults.checkInterval` seconds.
    ///
    /// Call once from `AppDelegate` after the startup sequence completes.
    /// The scheduler is owned by the system and does not need to be stored;
    /// it fires on a background queue and bridges back to `MainActor` for
    /// any `RunnerState` mutations.
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

        scheduler.schedule { completion in
            Task {
                let beta = await AppPreferencesStore.shared.betaChannel
                let result = await UpdateChecker.checkForUpdate(betaChannel: beta)
                await MainActor.run {
                    if case .updateAvailable(let release) = result {
                        state.setAvailableUpdate(release.tagName)
                        Task { await AutoUpdater.handle(release, state: state) }
                    }
                }
                completion(.finished)
            }
        }
    }

    // MARK: - Install & Relaunch

    /// Unzips the cached `RunBot.zip`, replaces the running `.app` bundle,
    /// and relaunches the new version.
    ///
    /// ## Flow
    /// 1. Unzip the cached zip into a temporary directory via `/usr/bin/ditto`.
    /// 2. Locate `RunBot.app` inside the unzipped contents.
    /// 3. Copy it over the running bundle path via `/bin/cp -R`.
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
        let bundlePath = Bundle.main.bundlePath  // e.g. …/RunBot.app

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
        // cp -R replaces the destination atomically enough for our purposes;
        // the running process keeps its open file descriptors until it exits.
        let cpResult = await runCommand("/bin/cp",
                                        args: ["-Rf", appInZip.path, bundlePath])
        guard cpResult else {
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
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", bundlePath]
        try? relaunchTask.run()

        NSApp.terminate(nil)
    }

    // MARK: - Process helper

    /// Runs a command synchronously on a background thread and returns `true`
    /// on exit code 0, `false` otherwise.
    ///
    /// Used for `ditto` (unzip) and `cp` (replace bundle) which are short-lived
    /// and do not need streaming output.
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
