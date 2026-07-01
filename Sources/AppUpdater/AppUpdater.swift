// AppUpdater.swift
// AppUpdater
import CryptoKit
import Foundation
// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AppUpdater

/// Drives the in-app auto-update flow: GitHub Releases poll → semver compare →
/// zip download → SHA-256 verification → host-state mutation → install &
/// relaunch on user confirmation.
///
/// `AppUpdater` is a configurable `@MainActor` class carrying no host-specific
/// state of its own beyond what the caller injects. All UI-facing state lives
/// in a caller-supplied `any UpdateStateProviding`; all persisted state lives
/// in the injected `UserDefaults` under keys scoped to `schedulerIdentifier`.
///
/// ## Isolation model
///
/// The class is `@MainActor`, so `isInstalling`, `isDownloading`, and the
/// scheduler reference are race-free without extra locking. The blocking work
/// runs off the main thread regardless: `URLSession` downloads suspend rather
/// than block, checksum verification runs in the `@concurrent` `verifyChecksum`
/// free function, and subprocess launches run in the `@concurrent` `runCommand`
/// helper. The background download is spawned with a plain `Task { }` that
/// inherits `@MainActor`, so `state` is captured in-actor and needs no
/// `Sendable` conformance across an actor boundary.
///
/// ## Typical usage
///
/// ```swift
/// let updater = AppUpdater(
///     repo: "your-org/your-repo",
///     currentVersion: "1.2.3",
///     assetName: { _ in "YourApp.zip" },
///     schedulerIdentifier: "com.your-org.update-check",
///     betaChannelProvider: { UserDefaults.standard.bool(forKey: "betaChannel") }
/// )
/// updater.rehydrateCachedUpdateIfNewer(state: myState)
/// await updater.checkAndHandle(state: myState)
/// updater.scheduleBackgroundCheck(state: myState)
/// ```
@MainActor
public final class AppUpdater {

    // MARK: - Injected configuration

    /// `"owner/name"` GitHub repository slug polled for releases.
    let repo: String

    /// The running app's version (full semver incl. any pre-release suffix).
    /// The library never reads `Bundle` — the host supplies this.
    let currentVersion: String

    /// Maps a release tag name to the expected zip asset filename.
    ///
    /// Injected so hosts can use a fixed name (`{ _ in "App.zip" }`) or a
    /// versioned one (`{ v in "App-\(v).zip" }`). The SHA-256 sidecar is
    /// expected at `<assetName>.sha256`.
    let assetName: (String) -> String

    /// Reverse-DNS identifier for the background scheduler; also the domain
    /// used to scope this updater's `UserDefaults` keys.
    let schedulerIdentifier: String

    /// The `UserDefaults` suite persisting the cached-zip path and version.
    let defaults: UserDefaults

    /// Reads the host's current beta-channel preference. Invoked on the main
    /// actor before each check so pre-release builds are included when enabled.
    let betaChannelProvider: @MainActor () -> Bool

    /// Scoped `UserDefaults` key names, derived from `schedulerIdentifier`.
    let keys: AppUpdaterDefaults

    // MARK: - Runtime flags

    /// `true` while `installAndRelaunch` is mid-flight — guards a double-tap.
    var isInstalling: Bool = false

    /// `true` while a background download is running — guards concurrent
    /// downloads of the same or a different release.
    var isDownloading: Bool = false

    // AppKit is unavailable in the SPM headless test runner — this guard is
    // required for `swift test` even though the package is macOS(.v26)-only.
    // Only deinit may access `activity` from a nonisolated context (invalidate
    // is thread-safe per Apple docs); all other reads/writes must be @MainActor.
    #if canImport(AppKit)
    /// Retains the `NSBackgroundActivityScheduler` for the app's lifetime.
    ///
    /// `nonisolated(unsafe)` so `deinit` (a nonisolated context) can invalidate
    /// it. Assigned and read only on the main actor otherwise.
    nonisolated(unsafe) var activity: NSBackgroundActivityScheduler?
    #endif

    // MARK: - Init / deinit

    /// Creates a configured updater.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug (e.g. `"runbot-hq/run-bot"`).
    ///     Must not be empty — an empty string produces a malformed API URL.
    ///   - currentVersion: The running app's version string.
    ///   - assetName: Maps a tag name to the expected zip asset filename.
    ///   - schedulerIdentifier: Reverse-DNS scheduler id / `UserDefaults` domain.
    ///     Must not be empty — an empty string causes `UserDefaults` key
    ///     collisions between instances (keys degrade to bare dot-prefixed strings).
    ///   - userDefaults: Suite for persisted cache state. Defaults to `.standard`.
    ///   - betaChannelProvider: Returns the host's beta-channel preference.
    ///     Defaults to always-`false` (stable channel only).
    public init(
        repo: String,
        currentVersion: String,
        assetName: @escaping (String) -> String,
        schedulerIdentifier: String,
        userDefaults: UserDefaults = .standard,
        betaChannelProvider: @escaping @MainActor () -> Bool = { false }
    ) {
        precondition(!repo.isEmpty, "AppUpdater: repo must not be empty (expected \"owner/repo\")")
        precondition(!schedulerIdentifier.isEmpty, "AppUpdater: schedulerIdentifier must not be empty (expected a reverse-DNS string)")
        self.repo = repo
        self.currentVersion = currentVersion
        self.assetName = assetName
        self.schedulerIdentifier = schedulerIdentifier
        self.defaults = userDefaults
        self.betaChannelProvider = betaChannelProvider
        self.keys = AppUpdaterDefaults(domain: schedulerIdentifier)
    }

    deinit {
        // NSBackgroundActivityScheduler must be explicitly invalidated;
        // failing to do so leaks the activity registration system-wide.
        // NSBackgroundActivityScheduler.invalidate() is thread-safe per Apple
        // docs — safe to call from a nonisolated deinit.
        #if canImport(AppKit)
        activity?.invalidate()
        #endif
    }

    // MARK: - Convenience entry points

    /// Runs a full update check and handles the result.
    ///
    /// On `.updateAvailable` the release is downloaded/cached via `handle`.
    /// `.upToDate` and `.failed` are no-ops here (the background scheduler owns
    /// the stale-row-clearing policy) — this mirrors a launch-time check that
    /// must never clear a ready-to-install update after a transient failure.
    public func checkAndHandle(state: any UpdateStateProviding) async {
        let beta = betaChannelProvider()
        switch await checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            appUpdaterLogger.debug("update available: \(release.tagName, privacy: .public) (beta=\(beta, privacy: .public))")
            await handle(release, state: state)
        case .upToDate:
            appUpdaterLogger.debug("no update available (beta=\(beta, privacy: .public))")
        case .failed(let error):
            appUpdaterLogger.debug("update check failed: \(String(describing: error), privacy: .public) (beta=\(beta, privacy: .public))")
        }
    }

    /// Runs a channel-aware update check against the configured repo.
    func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        await UpdateChecker.checkForUpdate(
            repo: repo,
            currentVersion: currentVersion,
            betaChannel: betaChannel,
            assetName: assetName
        )
    }

    /// Rehydrates cached download state on launch, if a newer zip is cached.
    ///
    /// Reads this updater's scoped `UserDefaults` keys. If a cached zip still
    /// exists on disk and its version is newer than `currentVersion`, the host
    /// state is rehydrated and the available-update label is set so the install
    /// affordance is visible immediately — even offline, before any network
    /// check runs. Otherwise stale keys are cleared.
    ///
    /// Call this before `checkAndHandle` on startup.
    public func rehydrateCachedUpdateIfNewer(state: any UpdateStateProviding) {
        guard let path = defaults.string(forKey: keys.cachedUpdateZipPath),
              let version = defaults.string(forKey: keys.cachedUpdateVersion),
              FileManager.default.fileExists(atPath: path),
              UpdateChecker.isNewer(version, than: currentVersion) else {
            // Reached when the keys were never written, the zip was deleted, or
            // the cached version is no longer newer (already installed). In all
            // cases clear the stale keys.
            clearCachedDefaults()
            return
        }
        state.rehydrateCachedUpdate(zipURL: URL(fileURLWithPath: path), version: version)
        state.setAvailableUpdate(version)
    }

    // MARK: - Entry point

    /// Responds to a newly discovered available release.
    ///
    /// 1. If a matching cached zip already exists for this version, rehydrates
    ///    the host state and returns without re-downloading.
    /// 2. If the release has no matching zip asset, sets the host failure state
    ///    (browser-download fallback) and returns.
    /// 3. Otherwise starts a background download; the host state is updated on
    ///    the main actor when it completes.
    ///
    /// The visible version label is set first so the host is never in a state
    /// where a cached zip is present but no version label is shown.
    public func handle(_ release: AvailableRelease, state: any UpdateStateProviding) async {
        state.setAvailableUpdate(release.tagName)

        // ── 1. Already cached? ──────────────────────────────────────────────
        let cachedVersion = defaults.string(forKey: keys.cachedUpdateVersion)
        let cachedPath = defaults.string(forKey: keys.cachedUpdateZipPath)
        if let cachedVersion, cachedVersion == release.tagName, let path = cachedPath {
            if FileManager.default.fileExists(atPath: path) {
                // `rehydrateCachedUpdate` sets the zip URL + version and clears
                // any stale failure flag from a prior session.
                state.rehydrateCachedUpdate(zipURL: URL(fileURLWithPath: path), version: cachedVersion)
                return
            }
            // Cached path no longer on disk — clear stale defaults and fall
            // through to a fresh download.
            clearCachedDefaults()
        }

        // ── 2. Asset absent from release? ───────────────────────────────────
        // A missing asset is signalled via `setAssetMissing()`, NOT
        // `setUpdateFailed()`: nothing was attempted and failed — the release
        // simply carries no binary. This mirrors the pre-refactor semantics
        // where the asset-absent path set only `updateAssetMissing`. Both flags
        // drive the same browser-download fallback, but keeping them distinct
        // preserves the more precise reason for the host UI.
        let wantedAsset = assetName(release.tagName)
        guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
            state.setAssetMissing()
            return
        }

        // ── 3. In-flight guard ──────────────────────────────────────────────
        // Drops any handle() call while a download is already running. Placed
        // AFTER the cache-hit and asset-missing early exits (which never start a
        // download) so it only guards the path it was designed for. When
        // isDownloading is true a prior failure cannot be pending (the failure
        // path clears the flag atomically with setUpdateFailed), so returning
        // early here leaves no stale state to reconcile.
        guard !isDownloading else { return }
        isDownloading = true

        // ── 3b. Move to downloading state ───────────────────────────────────
        // Clears any rehydrated older-version zip (in-memory) and the persisted
        // defaults, and clears the failure flag — forcing the host into its
        // spinner state while the new zip downloads. Clearing the defaults up
        // front closes the window where a force-quit mid-download would let a
        // superseded cached version be re-offered on next launch.
        state.setDownloadStarted()
        clearCachedDefaults()

        let downloadURL = asset.browserDownloadURL
        let checksumURL = release.checksumURL
        let tagName = release.tagName

        // Plain Task (not detached): inherits @MainActor, so `state` is captured
        // in-actor. The heavy work inside suspends (URLSession) or hops off-main
        // (@concurrent verifyChecksum), keeping the main thread free.
        //
        // Strong capture (no `[weak self]`) is deliberate and correct here. The
        // host owns `AppUpdater` as a stored `let` on its `NSApplicationDelegate`
        // (`AppDelegate.autoUpdater`), so it is a de facto singleton that lives
        // for the entire process lifetime — the updater can never be deallocated
        // between spawning this task and its resumption. A `weak` capture would
        // provide no real protection and instead introduce a latent stuck-state
        // bug: were `self` ever nil, `downloadUpdate` would never run, `isDownloading`
        // would stay `true` forever, and every later `handle()` call would silently
        // no-op via the in-flight guard — permanently breaking updates for that
        // session. Retaining `self` for the duration of the download is exactly
        // the intended lifetime.
        Task {
            await self.downloadUpdate(from: downloadURL, checksumURL: checksumURL, version: tagName, state: state)
        }
    }

    // MARK: - Download

    /// Downloads the zip and its SHA-256 sidecar in parallel, verifies
    /// integrity, then caches the verified zip and updates host state.
    ///
    /// The zip and checksum are fetched concurrently via `async let`. The digest
    /// is computed in the `@concurrent` `verifyChecksum` free function.
    /// Verification runs on the URLSession temp file **before** the file is
    /// moved into the cache, so an unverified zip never reaches the cache. On
    /// any failure the host failure state is set (browser-download fallback).
    private func downloadUpdate( // skipcq: SW-R1002 — reviewed; complexity acceptable for this download+verify flow
        from url: URL,
        checksumURL: URL?,
        version: String,
        state: any UpdateStateProviding
    ) async {
        // Hoisted so the catch block can clean up a written-but-unverified zip.
        var tempURL: URL?
        do {
            // Dedicated session with explicit timeouts — URLSession.shared has
            // none, so a stalled connection would hang indefinitely.
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 30
            sessionConfig.timeoutIntervalForResource = 300
            let session = URLSession(configuration: sessionConfig)
            defer { session.finishTasksAndInvalidate() }

            // Absent sidecar is a hard failure.
            guard let checksumURL else {
                throw URLError(.resourceUnavailable)
            }

            // Parallel fetch: zip + checksum sidecar. Both requests start when
            // the `async let` bindings are declared; the zip is awaited first so
            // `tempURL` is set before the checksum is awaited — if the checksum
            // fetch throws, the catch block can remove the already-written zip.
            async let zipDownload = session.download(from: url)
            async let checksumDownload = session.data(from: checksumURL)
            let (downloadedURL, zipResponse) = try await zipDownload
            tempURL = downloadedURL
            let (checksumData, _) = try await checksumDownload

            // GitHub's asset CDN returns exactly 200 on a full download; 206/304
            // cannot occur (no Range / conditional headers sent). Strict `!= 200`
            // avoids caching a partial or not-modified body as a valid zip.
            guard let http = zipResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }

            // Parse the expected hex digest from the sidecar. `shasum`/`sha256sum`
            // format is "<hex>  <filename>" — take the first whitespace token.
            // A decode failure falls back to "" → verifyChecksum throws a
            // mismatch → failure state (same safe outcome as a wrong checksum).
            let rawChecksum = String(bytes: checksumData, encoding: .utf8) ?? ""
            let expectedHex = rawChecksum
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? ""

            // Verify BEFORE moving to the cache. A failure here fires the catch
            // block, cleaning up temp; the cache directory is never written.
            try await verifyChecksum(zipURL: downloadedURL, expectedHex: expectedHex)

            let destination = try cachedZipDestination(version: version)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloadedURL, to: destination)

            // Persist so the install survives a relaunch.
            defaults.set(version, forKey: keys.cachedUpdateVersion)
            defaults.set(destination.path, forKey: keys.cachedUpdateZipPath)

            state.setDownloadComplete(zipURL: destination, version: version)
            isDownloading = false
        } catch {
            // Best-effort temp cleanup. `try?` swallows ENOENT if the OS already
            // evicted a partial download.
            if let tmp = tempURL {
                try? FileManager.default.removeItem(at: tmp)
            }
            // isDownloading cleared together with the failure flag so a
            // subsequent handle() never observes both true simultaneously.
            isDownloading = false
            state.setUpdateFailed()
        }
    }
}
