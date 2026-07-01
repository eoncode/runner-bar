// AppUpdaterBehaviorTests.swift
// AppUpdater
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterBehaviorTests

/// Exercises `AppUpdater.handle` decision paths that don't require the network:
/// the already-cached short-circuit and the in-flight download guard.
@MainActor
@Suite("AppUpdater.handle")
struct AppUpdaterBehaviorTests {

    /// Builds an `AppUpdater` bound to an isolated `UserDefaults` suite so the
    /// scoped cache keys never touch `.standard`.
    private func makeUpdater(domain: String, defaults: UserDefaults) -> AppUpdater {
        AppUpdater(
            repo: "example/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "RunBot.zip" },
            schedulerIdentifier: domain,
            userDefaults: defaults,
            betaChannelProvider: { false }
        )
    }

    private func makeAsset(_ name: String) throws -> ReleaseAsset {
        ReleaseAsset(
            name: name,
            browserDownloadURL: try #require(URL(string: "https://example.com/\(name)"))
        )
    }

    // MARK: - Cache hit

    /// When a cached zip for the discovered version already exists on disk,
    /// `handle` rehydrates host state and starts NO download.
    @Test func cacheHitRehydratesWithoutDownloading() async throws {
        let domain = "test.cachehit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        // Write a real temp file and point the scoped cache keys at it.
        let keys = AppUpdaterDefaults(domain: domain)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachehit-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        defaults.set("v9.9.9", forKey: keys.cachedUpdateVersion)
        defaults.set(tmp.path, forKey: keys.cachedUpdateZipPath)

        let updater = makeUpdater(domain: domain, defaults: defaults)
        let state = MockUpdateState()
        let release = AvailableRelease(tagName: "v9.9.9", assets: [], checksumURL: nil)

        await updater.handle(release, state: state)

        #expect(state.rehydrateCount == 1)
        #expect(state.downloadStartedCount == 0)
        #expect(state.updateZipURL == tmp)
        #expect(updater.isDownloading == false)
    }

    // MARK: - In-flight guard

    /// While a download is already running, a second `handle` for a downloadable
    /// release is dropped: no new "download started" transition occurs.
    @Test func inFlightDownloadGuardDropsSecondHandle() async throws {
        let domain = "test.inflight.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let updater = makeUpdater(domain: domain, defaults: defaults)
        updater.isDownloading = true // simulate an in-flight download

        let state = MockUpdateState()
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [try makeAsset("RunBot.zip")],
            checksumURL: URL(string: "https://example.com/RunBot.zip.sha256")
        )

        await updater.handle(release, state: state)

        // The available-update label is still set, but the download path is guarded.
        #expect(state.availableUpdates == ["v2.0.0"])
        #expect(state.downloadStartedCount == 0)
        #expect(state.updateZipURL == nil)
    }

    // MARK: - Missing asset

    /// A release with no matching zip asset flips the asset-missing state (browser
    /// fallback) and starts no download. The asset-missing path is distinct from
    /// the failure path: `setAssetMissing()` is called, `setUpdateFailed()` is not.
    @Test func missingAssetSetsAssetMissingWithoutDownloading() async throws {
        let domain = "test.noasset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let updater = makeUpdater(domain: domain, defaults: defaults)
        let state = MockUpdateState()
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [try makeAsset("SomethingElse.zip")],
            checksumURL: nil
        )

        await updater.handle(release, state: state)

        #expect(state.assetMissingCount == 1)
        #expect(state.updateAssetMissing == true)
        // Asset-missing is signalled separately from a download/install failure.
        #expect(state.updateFailedCount == 0)
        #expect(state.downloadStartedCount == 0)
        #expect(updater.isDownloading == false)
    }

    // MARK: - rehydrateCachedUpdateIfNewer fall-through

    /// When the cached zip path is recorded but the file no longer exists on
    /// disk, `rehydrateCachedUpdateIfNewer` must NOT rehydrate or set an
    /// available-update label, and MUST clear the stale scoped keys.
    @Test func rehydrateClearsWhenCachedPathMissingOnDisk() throws {
        let domain = "test.rehydrate.missingfile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        // Point the keys at a newer version but a path that does not exist.
        let keys = AppUpdaterDefaults(domain: domain)
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).zip").path
        defaults.set("v9.9.9", forKey: keys.cachedUpdateVersion)
        defaults.set(missingPath, forKey: keys.cachedUpdateZipPath)

        let updater = makeUpdater(domain: domain, defaults: defaults)
        let state = MockUpdateState()

        updater.rehydrateCachedUpdateIfNewer(state: state)

        #expect(state.rehydrateCount == 0)
        #expect(state.availableUpdates.isEmpty)
        #expect(defaults.string(forKey: keys.cachedUpdateVersion) == nil)
        #expect(defaults.string(forKey: keys.cachedUpdateZipPath) == nil)
    }

    /// When a cached zip exists on disk but its version is no longer newer than
    /// `currentVersion` (already installed), `rehydrateCachedUpdateIfNewer` must
    /// NOT rehydrate or set an available-update label, and MUST clear the keys.
    @Test func rehydrateClearsWhenCachedVersionNotNewer() throws {
        let domain = "test.rehydrate.notnewer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        // Write a real file, but record a version <= currentVersion ("1.0.0").
        let keys = AppUpdaterDefaults(domain: domain)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notnewer-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        defaults.set("v0.9.0", forKey: keys.cachedUpdateVersion)
        defaults.set(tmp.path, forKey: keys.cachedUpdateZipPath)

        let updater = makeUpdater(domain: domain, defaults: defaults)
        let state = MockUpdateState()

        updater.rehydrateCachedUpdateIfNewer(state: state)

        #expect(state.rehydrateCount == 0)
        #expect(state.availableUpdates.isEmpty)
        #expect(defaults.string(forKey: keys.cachedUpdateVersion) == nil)
        #expect(defaults.string(forKey: keys.cachedUpdateZipPath) == nil)
    }
}
