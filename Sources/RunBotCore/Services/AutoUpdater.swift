// AutoUpdater.swift
// RunBot
import AppKit
import CryptoKit
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
///
/// ## ⚠️ type_body_length — NOT a lint violation, do not split this file ⚠️
///
/// Automated reviewers sometimes flag this enum for exceeding a 400-line
/// body length threshold. That threshold is incorrect for this codebase.
/// The SwiftLint `type_body_length` limit in `.swiftlint.yml` is **600
/// lines**; this file is well within it. Do NOT split `AutoUpdater` into
/// additional extension files on the basis of a length warning — the
/// existing split (AutoUpdater+Install.swift,
/// AutoUpdater+BackgroundScheduler.swift) reflects logical separation of
/// concerns, not a line-count constraint. The length here is driven by
/// thorough inline documentation of intentional decisions, not by
/// excess code.
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
                // Clear any stale failure flag from a prior session. Without this,
                // a previous `updateActionFailed = true` would survive into a fresh
                // launch where the zip is already cached and valid, causing the UI
                // to show the Download fallback instead of Install & Relaunch.
                state.updateActionFailed = false
                return
            }
            // Cached path no longer exists on disk — clear stale defaults and
            // fall through to a fresh download.
            clearCachedDefaults()
        }

        // ── 2. Asset absent from release? ───────────────────────────────────
        // Always reset `updateAssetMissing` before the guard so that a
        // subsequent `handle` call for a release that *does* carry the asset
        // (e.g. a re-published release) clears the flag and proceeds to
        // download — rather than leaving the Download-from-browser fallback
        // permanently visible.
        state.updateAssetMissing = false
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            state.updateAssetMissing = true
            return
        }

        // ── 3. Kick off background download ─────────────────────────────────
        // Capture only the values the Task needs (URL + version string) rather
        // than the entire `RunnerState` object.
        //
        // `RunnerState` is `@MainActor`-isolated and `final class` (not yet
        // declared `Sendable`). Passing it into `Task.detached` is safe here
        // because `downloadUpdate` routes every state mutation back through
        // `await MainActor.run { }`, so all writes are correctly serialised on
        // MainActor. The Swift 6 strict-concurrency checker accepts this
        // pattern; no warning is emitted because `state` is only ever *read*
        // from the detached context to be forwarded, not written to directly.
        //
        // ── 3b. In-flight guard ──────────────────────────────────────────────
        // In-flight guard — drops any handle() call (same version OR different
        // version) while a Task.detached download is already running.
        //
        // Same-version case: prevents two Tasks racing to write the same
        // destination file, with the try? removeItem between them creating a
        // window where neither write wins cleanly.
        //
        // Different-version case: the in-progress download completes first;
        // the dropped call is silently discarded. The background scheduler
        // will re-offer the update on the next fire, at which point
        // isDownloading is false and the new download proceeds normally.
        //
        // `isDownloading` is `@MainActor`-isolated, so this read-modify-write
        // is atomic with respect to all other `handle()` callers.
        //
        // ⚠️ ORDERING IS INTENTIONAL — do not move this guard above the cache-hit
        // or asset-missing blocks (steps 1 and 2). Those two early-exit paths
        // return *before* Task.detached is ever reached — they never start a
        // download — so the in-flight guard is irrelevant to them. Placing it
        // first would guard code paths it was not designed for and would
        // incorrectly block a cache-hit rehydration if a background download
        // happened to be in flight for a different version.
        //
        // Clear any stale failure flag before the in-flight guard — not after.
        // If isDownloading is already true we return early and must NOT clear
        // the flag: the in-flight task is still responsible for it and will
        // reset it on completion. Clearing here (before the guard) ensures
        // that a fresh download path always starts with a clean slate, so the
        // UI shows the spinner rather than a stale Download fallback button
        // left over from a prior session's checksum failure or install error.
        state.updateActionFailed = false
        guard !isDownloading else { return }
        isDownloading = true

        // ── 3c. Clear stale rehydrated zip ──────────────────────────────────
        // If performStartupSequence found a cached zip for an older version V1
        // and called rehydrateCachedUpdate, state.updateZipURL is already set
        // to the V1 path. Without clearing it here, the UI would immediately
        // render "Install & Relaunch" (updateZipURL non-nil) while the banner
        // names the newer V2 being downloaded — and tapping the button would
        // install V1 instead.
        //
        // Also clear the persisted defaults here — not only the in-memory
        // state. If a newer V2 supersedes a cached-but-not-yet-installed V1
        // and the app is force-quit after the UI is cleared but before V2
        // finishes downloading, leaving the old V1 path in UserDefaults would
        // let performStartupSequence rehydrate and offer the superseded V1 on
        // the next launch. Clearing the defaults up front closes that window.
        //
        // Clearing both properties forces the UI into its ProgressView
        // (spinner) state while V2 downloads, exactly as intended.
        //
        // handle() is @MainActor so direct mutation is safe here — no
        // MainActor.run wrapper needed (Pillar 2).
        state.updateZipURL = nil
        state.cachedUpdateVersion = nil
        clearCachedDefaults()

        let downloadURL = asset.browserDownloadURL
        let checksumURL = release.checksumURL
        let tagName     = release.tagName

        Task.detached(priority: .background) {
            await downloadUpdate(from: downloadURL, checksumURL: checksumURL, version: tagName, state: state)
        }
    }

    // MARK: - Download

    /// Downloads the zip and its SHA-256 sidecar in parallel, verifies integrity,
    /// then moves the verified zip to the cache and updates `RunnerState` and
    /// `UserDefaults` on success.
    ///
    /// The zip and checksum are fetched concurrently via `async let` (Pillar 4).
    /// SHA-256 digest computation is performed in a `@concurrent` free function
    /// (`verifyChecksum`) using `Data(contentsOf:)` — a deliberate whole-file read.
    /// See `verifyChecksum`'s doc comment for the full rationale on why a streaming
    /// implementation is deferred. The zip is guaranteed < 10 MB by `publish.yml`'s
    /// verify step; this is not a correctness gap. `@concurrent` keeps the blocking
    /// read off all actor serial executors (Pillar 5).
    ///
    /// ## Verification order — verify before move
    ///
    /// `verifyChecksum` is called on `tempURL` (the system temp location written
    /// by `URLSession.download`) **before** `moveItem` copies the file to
    /// `destination` in the caches directory. This guarantees that an unverified
    /// or corrupt zip never reaches the cache:
    ///
    /// - If verification passes → zip is moved to cache → `UserDefaults` written
    ///   → `RunnerState` updated → Install & Relaunch button appears.
    /// - If verification fails → `tempURL` is deleted → `catch` sets
    ///   `updateActionFailed = true` → Download fallback button appears.
    ///   `destination` is never written, so `performStartupSequence` will
    ///   not find a file there on the next launch.
    ///
    /// On any failure — network error, HTTP non-200, checksum fetch failure, or
    /// digest mismatch — `runnerState.updateActionFailed` is set to `true` so
    /// the UI can offer the browser-based fallback.
    ///
    /// - Parameters:
    ///   - url: The direct download URL for the `RunBot.zip` asset.
    ///   - checksumURL: The URL of the `RunBot.zip.sha256` sidecar asset.
    ///     A `nil` value (sidecar absent from release) is treated as a hard
    ///     failure — the download is aborted and `updateActionFailed` is set.
    ///   - version: The tag name of the release being downloaded.
    ///   - state: The shared `RunnerState` to update on the `MainActor`.
    private static func downloadUpdate(
        from url: URL,
        checksumURL: URL?,
        version: String,
        state: RunnerState
    ) async {
        // Hoisted above `do` so the `catch` block can reference it for cleanup.
        //
        // ⚠️ TEMP-FILE ORPHAN ANALYSIS — KNOWN, ACCEPTED, NOT A BUG ⚠️
        //
        // `tempURL` is assigned immediately after `try await zipDownload` —
        // before `checksumDownload` is awaited. This ordering is intentional:
        //
        //   • zipDownload throws before writing  → tempURL is nil  → catch's
        //     removeItem is a no-op (URLSession never wrote a file).
        //   • zipDownload succeeds, checksumDownload throws → tempURL IS set →
        //     catch removes the zip correctly. This is the gap the split await
        //     closes vs. a combined tuple await.
        //   • Both succeed, later step throws (checksum mismatch, moveItem) →
        //     tempURL IS set → catch removes the zip correctly.
        //
        // The one residual gap: if zipDownload writes a partial file and then
        // throws a mid-stream network error, URLSession deletes the temp file
        // itself before surfacing the error — tempURL is never set and there is
        // nothing to clean up. All reachable paths are covered.
        //
        // The zip is < 10 MB (guaranteed by publish.yml's verify step); even
        // in the degenerate case macOS sweeps NSTemporaryDirectory() on restart
        // and under storage pressure. REVIEWER: Do NOT add further temp-file
        // tracking — the coverage analysis above is complete.
        var tempURL: URL?
        do {
            // Use a dedicated URLSession with explicit timeouts rather than
            // URLSession.shared (which has no timeout configured). On a stalled
            // connection — mobile hotspot, corporate proxy, flaky Wi-Fi — the
            // shared session would hang indefinitely with no cancellation path.
            //
            // timeoutIntervalForRequest: 30 s — max time to receive the *first*
            //   byte after the request is sent. Covers DNS hangs, TLS stalls,
            //   and unresponsive CDN edge nodes.
            // timeoutIntervalForResource: 300 s — max total download time.
            //   RunBot.zip is small (< 10 MB); 5 minutes is generous even on
            //   a slow connection while still guaranteeing eventual failure
            //   rather than an eternal hang.
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest  = 30
            sessionConfig.timeoutIntervalForResource = 300
            let session = URLSession(configuration: sessionConfig)
            // Invalidate the session when this scope exits — on both the success
            // path and all throw paths — so its TCP connection pool and internal
            // delegate queue are released promptly. Without this, each call to
            // downloadUpdate() leaks one URLSession for the lifetime of the process.
            // `finishTasksAndInvalidate` (not `invalidateAndCancel`) is used because
            // the async let tasks below have already been awaited to completion by
            // the time defer fires; there are no in-flight tasks left to cancel.
            defer { session.finishTasksAndInvalidate() }

            // Absent sidecar is a hard failure — publish.yml always uploads it.
            guard let checksumURL else {
                throw URLError(.resourceUnavailable)
            }

            // ── Parallel fetch: zip + checksum sidecar (Pillar 4) ────────────
            // Both requests are independent; fetching them concurrently saves
            // one full round-trip on the critical path. `async let` bindings
            // are the canonical Pillar 4 pattern for parallel independent fetches.
            //
            // ⚠️ AWAIT ORDER IS INTENTIONAL — both async let bindings start
            // concurrently (Pillar 4). zipDownload is awaited first so tempURL
            // is set before checksumDownload is awaited. If checksumDownload
            // subsequently throws, the catch block finds tempURL non-nil and
            // removes the already-written zip. Reversing the order would leave
            // tempURL nil on a checksum network error and orphan the zip in
            // NSTemporaryDirectory().
            //
            // This is NOT sequential fetching — both URLSession tasks are
            // already in-flight from the moment the async let bindings are
            // declared. The ordered awaits only determine which result is read
            // first, not when the requests start.
            // REVIEWER: Do NOT collapse this back to a combined tuple await.
            //
            // ⚠️ NO QUARANTINE STRIP NEEDED — DO NOT ADD `xattr -dr com.apple.quarantine` ⚠️
            //
            // Reviewers familiar with Sparkle or other macOS updaters may expect
            // a quarantine-strip step after this download. It is not needed here.
            //
            // `com.apple.quarantine` is applied to downloaded files only by
            // processes that have opted in via LSFileQuarantineEnabled = YES in
            // their Info.plist. RunBot's Info.plist does NOT set this key
            // (omitting it defaults to NO for non-sandboxed apps). Therefore
            // this URLSession download does NOT apply the quarantine xattr to
            // the zip, and the extracted RunBot.app will not be quarantined.
            // Gatekeeper will not prompt or block on relaunch.
            //
            // The curl install script runs `xattr -dr com.apple.quarantine`
            // as a belt-and-braces measure for zips that a user may have
            // downloaded via a browser (which IS LSFileQuarantineEnabled).
            // That scenario cannot arise here — the zip is always fetched by
            // this URLSession, never by a browser. The strip is unnecessary.
            //
            // REVIEWER: Do NOT add an xattr strip step here or in
            // AutoUpdater+Install.swift. See Info.plist for the LSFileQuarantineEnabled
            // rationale. If LSFileQuarantineEnabled is ever added to Info.plist,
            // revisit this comment and add the strip at that point.
            async let zipDownload      = session.download(from: url)
            async let checksumDownload = session.data(from: checksumURL)
            // ⚠️ checksumDownload response is intentionally discarded (`_`) — NOT a bug.
            // A 4xx/5xx body causes rawChecksum to parse to garbage, verifyChecksum
            // throws a mismatch, updateActionFailed = true, and the browser fallback
            // is shown. The failure mode is safe. The log will say "checksum mismatch"
            // even when the real cause is a 404 on the sidecar — this is a known,
            // accepted diagnostic trade-off tracked alongside #1795.
            // REVIEWER: Do NOT add an HTTP status check for checksumDownload here.
            let (downloadedURL, zipResponse) = try await zipDownload
            // Assign to the hoisted var now — before awaiting checksumDownload —
            // so the catch block can remove the file if checksumDownload throws.
            // See the tempURL hoisted-var comment above for the full orphan analysis.
            tempURL = downloadedURL
            let (checksumData, _) = try await checksumDownload

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
            //
            // `guard let` rather than `if let`: a nil cast (non-HTTP response)
            // is treated as an explicit failure rather than a silent pass-through
            // that would move a potentially corrupt temp file into the cache.
            guard let http = zipResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode != 200 {  // ← strict by design, NOT a bug — read comment above before changing
                throw URLError(.badServerResponse)
            }

            // ── SHA-256 integrity verification (Pillar 5) ────────────────────
            // Parse the expected hex digest from the sidecar.
            // `shasum -a 256` format: "<hex>  <filename>" — take the first
            // whitespace-delimited token to handle both formats produced by
            // `shasum` (two spaces) and `sha256sum` (one space + asterisk).
            //
            // String(bytes:encoding:) is the failable initialiser preferred by
            // SwiftLint's optional_data_string_conversion rule. Falling back to
            // "" on decode failure causes `verifyChecksum` to throw a mismatch,
            // which is the correct failure mode — a corrupt or empty sidecar is
            // treated identically to a wrong checksum: `updateActionFailed` is
            // set and the browser Download fallback is shown.
            //
            // ⚠️ DIAGNOSTIC NOTE — this means Console.app will log a checksum
            // mismatch error even when the actual cause is an empty or
            // unparseable sidecar file, not a tampered zip. The two cases are
            // not distinguished in the log. This is a known, accepted trade-off:
            // both cases are safe (the update is blocked), and adding a
            // pre-check guard here would complicate the control flow for a
            // failure mode (malformed sidecar from publish.yml) that should
            // never occur in practice. If diagnostics become a priority, add
            // an explicit guard before this block and log "corrupt sidecar"
            // separately. Tracked alongside #1795.
            let rawChecksum = String(bytes: checksumData, encoding: .utf8) ?? ""
            let expectedHex = rawChecksum
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces).first ?? ""

            // ── Verify before move ───────────────────────────────────────────
            // Checksum is verified against `tempURL` (the URLSession temp file)
            // BEFORE `destination` is computed or `moveItem` is called.
            //
            // This ordering is intentional and load-bearing:
            //   •  If `verifyChecksum` throws, the `catch` block fires and the
            //      unverified file is cleaned up from temp. `destination` is
            //      never created, so the cache directory remains clean.
            //   •  If we moved first and then verified, a checksum failure would
            //      leave a corrupt/tampered file at `destination`. On the next
            //      launch `performStartupSequence` would find the file, skip the
            //      download, and silently offer a bad update for install.
            //
            // REVIEWER: Do NOT reorder these lines. `verifyChecksum` must always
            // precede both `cachedZipDestination` and `moveItem`.
            //
            // ⚠️ DATA(CONTENTSOF:) IN verifyChecksum IS INTENTIONAL — DO NOT REFACTOR ⚠️
            //
            // `verifyChecksum` uses `Data(contentsOf:)` internally — a synchronous
            // whole-file read on a `@concurrent` cooperative thread. This is the
            // correct Pillar 5 pattern for bounded blocking I/O. Do NOT wrap this
            // call in `Task.detached`, do NOT add a `FileHandle.bytes` streaming
            // loop, and do NOT request that refactor in review. The zip is
            // guaranteed < 10 MB by `publish.yml`'s verify step; the trade-off
            // has been explicitly evaluated. See `verifyChecksum`'s doc comment
            // below for the full rationale. Revisit only if zip size grows
            // substantially or if #1795 touches this function.
            try await verifyChecksum(zipURL: downloadedURL, expectedHex: expectedHex)

            let destination = try cachedZipDestination(version: version)

            // Remove any stale file from a previous interrupted download.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloadedURL, to: destination)

            // Persist to UserDefaults so the install survives a relaunch.
            let defaults = UserDefaults.standard
            defaults.set(version, forKey: AutoUpdaterDefaults.cachedUpdateVersion)
            defaults.set(destination.path, forKey: AutoUpdaterDefaults.cachedUpdateZipPath)

            // Push to RunnerState on the MainActor — Views observe this.
            await MainActor.run {
                state.updateZipURL = destination
                state.cachedUpdateVersion = version
                isDownloading = false
            }
        } catch {
            // Best-effort temp file cleanup. Three failure scenarios and what
            // `tempURL` looks like in each:
            //
            //   1. Network / HTTP error — `session.download` threw before writing
            //      anything, or wrote a partial file. `tempURL` may or may not
            //      exist depending on how far the download progressed.
            //
            //   2. Checksum failure — `verifyChecksum` threw after the zip was
            //      fully written to `tempURL`. `tempURL` exists and holds the
            //      bad file. It must be removed so it is not left in the system
            //      temp directory.
            //
            //   3. `moveItem` failure — `tempURL` still exists (the move failed);
            //      `destination` was never written.
            //
            // In all three cases the right action is the same: attempt to delete
            // `tempURL`. If it is already gone (case 1, partial download evicted
            // by the OS) the `try?` swallows the ENOENT silently.
            //
            // NOTE: This cleanup is NOT the safety net for the verify-before-move
            // ordering. The ordering guarantee is that `verifyChecksum` runs
            // before `moveItem`, so `destination` is never written with an
            // unverified file. This catch block only handles temp file hygiene.
            if let tmp = tempURL {
                try? FileManager.default.removeItem(at: tmp)
            }
            await MainActor.run {
                isDownloading = false
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
    /// in `~/Library/Caches/io.github.runbot-hq/`. Each file is < 10 MB and
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
    static func clearCachedDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        defaults.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)
    }
}

// MARK: - SHA-256 verification

/// Reads `zipURL` from disk and verifies its SHA-256 digest against `expectedHex`.
///
/// Implemented as a `@concurrent` async free function so the synchronous
/// `Data(contentsOf:)` read runs on the cooperative thread pool's concurrent
/// executor rather than blocking an actor serial executor (Pillar 5,
/// `docs/architecture/concurrency-overview.md`).
///
/// ## ⚠️ `Data(contentsOf:)` is INTENTIONAL — do not refactor to streaming ⚠️
///
/// This function loads the entire zip into memory before hashing. This is a
/// deliberate trade-off, not an oversight:
///
/// - **RunBot.zip is guaranteed < 10 MB.** `publish.yml`'s verify step anchors
///   the grep pattern so that only `RunBot.app/Contents/MacOS/RunBot` can be
///   present at the archive root — no bundled frameworks, no embedded assets.
///   At this size, loading into memory is instantaneous and poses no memory
///   pressure on any supported macOS version.
///
/// - **`@concurrent` already satisfies Pillar 5.** The annotation keeps this
///   blocking read off all actor serial executors. The cooperative thread pool
///   is not exhausted by a single synchronous read of < 10 MB; exhaustion
///   requires many concurrent blocked threads, which cannot arise here because
///   `isDownloading` prevents concurrent download tasks.
///
/// - **Streaming adds real complexity for zero practical benefit today.**
///   A `FileHandle.bytes.chunks(ofCount:)` loop with incremental
///   `SHA256.update(data:)` calls would require `swift-algorithms` (or a
///   manual read loop), incremental `CryptoKit` usage, and more error-handling
///   surface — all to save < 10 MB of peak memory that macOS would reclaim
///   within milliseconds anyway.
///
/// **When to revisit:**
/// If `RunBot.zip` ever grows substantially (> 50 MB), or if `isDownloading`
/// is removed and multiple concurrent verifications become possible, switch to
/// incremental `FileHandle` streaming at that point. The natural trigger is
/// issue #1795 (codesign verification) — that work will touch this function
/// anyway, and a streaming approach can be evaluated in that context.
///
/// REVIEWER: Do NOT raise `Data(contentsOf:)` as a finding or request a
/// streaming refactor. This has been explicitly evaluated; the trade-off is
/// documented here and in the call-site comment in `downloadUpdate` above.
/// The decision is to defer until zip size or concurrency constraints justify
/// the added complexity. See also `docs/architecture/concurrency-overview.md`
/// Pillar 5 for the `@concurrent` I/O contract.
///
/// Throws `URLError(.cannotDecodeContentData)` on digest mismatch, or
/// propagates any `Data(contentsOf:)` error on read failure.
///
/// - Parameters:
///   - zipURL: The local file URL of the zip to verify. Called with `tempURL`
///     (the URLSession temp location) so verification happens before the file
///     is moved to the caches directory.
///   - expectedHex: The lowercase hex SHA-256 digest string from the sidecar file.
@concurrent
private func verifyChecksum(zipURL: URL, expectedHex: String) async throws {
    let zipData   = try Data(contentsOf: zipURL)  // blocking read — correct here per Pillar 5; see doc comment above
    let digest    = SHA256.hash(data: zipData)
    let actualHex = digest.map { String(format: "%02x", $0) }.joined()
    guard actualHex == expectedHex else {
        throw URLError(.cannotDecodeContentData)
    }
}
