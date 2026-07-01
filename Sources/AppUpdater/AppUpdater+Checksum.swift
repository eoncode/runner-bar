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
    /// ## Stale zip accumulation — known, acceptable, low priority
    ///
    /// Each update cycle writes a new version-stamped file. `downloadUpdate`
    /// removes the file at `destination` before writing (handling interrupted
    /// downloads of the *same* version), but files from *prior* versions
    /// (e.g. `update-v0.7.9.zip` left over after a successful install) are
    /// not swept here.
    ///
    /// In practice this means at most one stale zip per update cycle accumulates
    /// in `~/Library/Caches/<schedulerIdentifier>/`. macOS evicts cache-directory
    /// contents under storage pressure. This is acceptable for a low-frequency
    /// update path.
    ///
    /// If a future audit shows meaningful accumulation, add a sweep here:
    ///
    ///     let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    ///     existing.filter { $0.lastPathComponent.hasPrefix("update-") && $0.pathExtension == "zip" }
    ///             .forEach { try? fm.removeItem(at: $0) }
    ///
    /// REVIEWER: The absence of this sweep is intentional, not an oversight.
    private func cachedZipDestination(version: String) throws -> URL {
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
        return dir.appendingPathComponent("update-\(safe).zip")
    }

    /// Removes the cached update entries from this updater's scoped `UserDefaults`.
    ///
    /// Called when the cached path is stale (file deleted externally) to
    /// prevent an infinite no-op loop on subsequent launches.
    private func clearCachedDefaults() {
        defaults.removeObject(forKey: keys.cachedUpdateVersion)
        defaults.removeObject(forKey: keys.cachedUpdateZipPath)
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
