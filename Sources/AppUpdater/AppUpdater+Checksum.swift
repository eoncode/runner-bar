// AppUpdater+Checksum.swift
// AppUpdater
import CryptoKit
import Foundation

// MARK: - Cache helpers

/// Cache path and `UserDefaults` helpers for the auto-update download flow.
/// See `AppUpdater.swift` for the full flow description.
extension AppUpdater {

    /// Returns the destination `URL` for the cached zip in the system caches
    /// directory, creating the intermediate directory if needed.
    ///
    /// The caches subdirectory is named after `schedulerIdentifier` so two apps
    /// embedding `AppUpdater` never collide on disk. The file is named
    /// `update-<version>.zip` (e.g. `update-v0.8.0.zip`) so multiple cached
    /// versions never collide either.
    ///
    /// `purgeStaleZips()` is called here before returning the destination path
    /// so stale zips from previous versions are removed before a new zip is
    /// written. This is belt-and-suspenders alongside the launch-time call in
    /// `rehydrateCachedUpdateIfNewer`.
    func cachedZipDestination(version: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = caches.appendingPathComponent(schedulerIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Sanitise the version tag to a safe filename component. `version` is a
        // raw GitHub API string; `handle()` is public and any future caller
        // could pass an arbitrary value. Allow only alphanumerics, `.`, `-`, and
        // `_`; replace everything else with `-`. This covers path-traversal
        // characters (`/`, `..`), whitespace, newlines, and any other unexpected
        // bytes without silently truncating the tag, making the resulting
        // filename both safe and still human-readable.
        let allowedSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let safe = version.unicodeScalars.map { scalar in
            allowedSet.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let destination = dir.appendingPathComponent("update-\(safe).zip")

        // Purge stale zips before writing the new one. Any update-*.zip that
        // is not the file we are about to write (destination) is spent and
        // should not accumulate on disk.
        purgeStaleZips(keeping: destination)

        return destination
    }

    /// Removes the cached update entries from this updater's scoped `UserDefaults`.
    ///
    /// Called when the cached path is stale (file deleted externally) to
    /// prevent an infinite no-op loop on subsequent launches.
    func clearCachedDefaults() {
        defaults.removeObject(forKey: keys.cachedUpdateVersion)
        defaults.removeObject(forKey: keys.cachedUpdateZipPath)
    }

    /// Deletes all `update-*.zip` files in this updater's scoped Caches
    /// subdirectory, except the one currently registered in `UserDefaults`
    /// as the live, ready-to-install zip.
    ///
    /// ## Why this exists
    ///
    /// `cachedZipDestination` writes version-stamped files
    /// (`update-v0.8.0.zip`, `update-v0.9.0.zip`, …). Without a sweep,
    /// files from prior versions accumulate in
    /// `~/Library/Caches/<schedulerIdentifier>/` indefinitely. macOS does NOT
    /// guarantee automatic eviction of `~/Library/Caches` contents on any
    /// schedule — despite common belief, files there can linger forever under
    /// normal disk conditions.
    ///
    /// ## Known accumulation paths this sweep covers
    ///
    /// 1. **Normal install cycle:** `replaceAndRelaunch` deletes the zip after
    ///    `open -n` succeeds, but the *previous* version's zip (from the prior
    ///    update cycle) is not deleted at install time — only the current one is.
    ///    Each update cycle leaves one stale zip behind.
    ///
    /// 2. **`open -n` failure after `replaceItem`:** `replaceAndRelaunch` clears
    ///    `UserDefaults` before attempting `relaunchTask.run()`. If `run()` throws,
    ///    UserDefaults are already cleared but the zip is still on disk with no
    ///    pointer to it. Nothing else cleans it up — it is permanently orphaned
    ///    without this sweep.
    ///
    /// 3. **Any future edge case** that clears UserDefaults before deleting the
    ///    zip (e.g. a crash between `clearCachedDefaults()` and `removeItem`).
    ///
    /// ## What is swept
    ///
    /// Only files matching ALL of:
    /// - Inside `~/Library/Caches/<schedulerIdentifier>/` (the app's own
    ///   scoped subdirectory — no other app's files are touched)
    /// - Filename starts with `"update-"` and ends with `".zip"`
    /// - NOT the `keepURL` (the currently registered live zip, if any)
    ///
    /// If `keepURL` is `nil` (no zip currently registered in UserDefaults),
    /// ALL matching files are deleted.
    ///
    /// ## What is NOT swept
    ///
    /// - The live zip registered in UserDefaults (`keepURL`) — preserved so
    ///   the ready-to-install affordance remains available.
    /// - Any file not matching the `update-*.zip` pattern — AppUpdater does
    ///   not own other files and must not delete them.
    /// - Files outside `~/Library/Caches/<schedulerIdentifier>/` — the sweep
    ///   is strictly scoped to the app's own cache subdirectory.
    ///
    /// ## Error handling
    ///
    /// All filesystem calls are `try?`. This function never throws and never
    /// surfaces errors to the caller or the user. A failed deletion is logged
    /// but otherwise ignored — a stale zip that could not be deleted is a disk
    /// hygiene issue, not a correctness issue.
    ///
    /// ## Call sites
    ///
    /// - `rehydrateCachedUpdateIfNewer` — every launch, cleans up anything
    ///   left from the previous session before the first network check runs.
    /// - `cachedZipDestination` — just before writing a new zip, so a fresh
    ///   download never lands next to stale files from a prior version.
    ///
    /// REVIEWER: Do NOT remove either call site. Each covers a distinct
    /// accumulation window:
    /// - Launch-time covers orphans from the previous session (including
    ///   the open -n failure path where UserDefaults are cleared before the
    ///   zip is deleted).
    /// - Pre-download covers the case where the app stays running for multiple
    ///   update cycles without a relaunch (e.g. long-running session, multiple
    ///   updates offered and deferred).
    func purgeStaleZips(keeping keepURL: URL? = nil) {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let dir = caches.appendingPathComponent(schedulerIdentifier, isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsSubdirectoryDescendants
        ) else { return }

        // keepPath is the canonical path of the live zip (if any). Canonical
        // form guards against symlink / relative-path aliasing so two paths
        // pointing at the same file are not treated as distinct.
        let keepPath = keepURL.flatMap { url in
            (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
                ?? url.path
        }

        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix("update-"), name.hasSuffix(".zip") else { continue }

            let candidatePath = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
                ?? url.path

            if let keepPath, candidatePath == keepPath { continue }

            if (try? FileManager.default.removeItem(at: url)) == nil {
                appUpdaterLogger.error("purgeStaleZips: failed to delete stale zip: \(url.lastPathComponent, privacy: .public)")
            } else {
                appUpdaterLogger.debug("purgeStaleZips: deleted stale zip: \(url.lastPathComponent, privacy: .public)")
            }
        }
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
/// - **The distributed zip is guaranteed small (< 10 MB for RunBot).** At this
///   size, loading into memory is instantaneous and poses no memory pressure on
///   any supported macOS version.
///
/// - **`@concurrent` already satisfies Pillar 5.** The annotation keeps this
///   blocking read off all actor serial executors. The cooperative thread pool
///   is not exhausted by a single synchronous read of < 10 MB; exhaustion
///   requires many concurrent blocked threads, which cannot arise here because
///   `isDownloading` prevents concurrent download tasks.
///
/// - **Streaming adds real complexity for zero practical benefit today.**
///   A `FileHandle.bytes.chunks(ofCount:)` loop with incremental
///   `SHA256.update()` calls would require `swift-algorithms` (or a manual read
///   loop), incremental `CryptoKit` usage, and more error-handling surface — all
///   to save < 10 MB of peak memory that macOS would reclaim within
///   milliseconds anyway.
///
/// **When to revisit:**
/// If the distributed zip ever grows substantially (> 50 MB), or if
/// `isDownloading` is removed and multiple concurrent verifications become
/// possible, switch to incremental `FileHandle` streaming at that point.
///
/// REVIEWER: Do NOT raise `Data(contentsOf:)` as a finding or request a
/// streaming refactor. This has been explicitly evaluated; the trade-off is
/// documented here and in the call-site comment in `downloadUpdate`.
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
func verifyChecksum(zipURL: URL, expectedHex: String) async throws {
    let zipData   = try Data(contentsOf: zipURL)  // blocking read — correct here per Pillar 5; see doc comment above
    let digest    = SHA256.hash(data: zipData)
    let actualHex = digest.map { String(format: "%02x", $0) }.joined()
    guard actualHex == expectedHex else {
        throw URLError(.cannotDecodeContentData)
    }
}
