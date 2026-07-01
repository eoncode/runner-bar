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

    /// Creates a `ReleaseAsset` with the given filename, using an
    /// `https://example.com/<name>` download URL. Throws if the URL cannot be
    /// constructed (which in practice never happens for these fixture values).
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

        // The available-update label is not advanced while another download is in flight.
        #expect(state.availableUpdates.isEmpty)
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
    /// When the cached zip path is recorded in `UserDefaults` but the file is
    /// no longer present on disk, `rehydrateCachedUpdateIfNewer` must skip
    /// rehydration, leave the available-update label unset, and clear both
    /// stale scoped keys so they don't persist across launches.
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

    /// When a cached zip exists on disk but its version is not newer than
    /// `currentVersion` — meaning the update was already installed —
    /// `rehydrateCachedUpdateIfNewer` must skip rehydration, leave the
    /// available-update label unset, and clear both scoped keys so the
    /// already-applied update is not offered again.
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

// MARK: - AppUpdaterCheckAndHandleTests

/// Exercises `AppUpdater.checkForUpdate(betaChannel:)` in isolation using
/// `MockReleaseProvider` — no network, no disk I/O.
///
/// All tests share `currentVersion = "1.0.0"` on the updater and a
/// `"v2.0.0"` tag on the available release (clearly newer).
@MainActor
@Suite("AppUpdater.checkAndHandle")
struct AppUpdaterCheckAndHandleTests {

    private let newerTag = "v2.0.0"
    private let olderTag = "v0.9.0"
    private let currentVersion = "1.0.0"

    /// Builds an `AppUpdater` wired to `provider` and an isolated
    /// `UserDefaults` suite.
    private func makeUpdater(
        domain: String,
        defaults: UserDefaults,
        provider: some ReleaseProvider,
        betaChannel: Bool = false
    ) -> AppUpdater {
        AppUpdater(
            repo: "example/repo",
            currentVersion: currentVersion,
            assetName: { _ in "RunBot.zip" },
            schedulerIdentifier: domain,
            userDefaults: defaults,
            betaChannelProvider: { betaChannel },
            releaseProvider: provider
        )
    }

    /// Minimal `AvailableRelease` fixture — no assets, no checksum URL.
    /// Sufficient for `checkForUpdate` tests which only inspect the tag.
    private func release(tag: String) -> AvailableRelease {
        AvailableRelease(tagName: tag, assets: [], checksumURL: nil)
    }

    // MARK: - 1. Provider returns nil → .failed

    /// When the provider returns `nil` (simulates network failure / empty
    /// releases list), `checkForUpdate` must return `.failed(.noReleasesFound)`
    /// and leave `isDownloading` false.
    @Test func providerReturnsNil_failedNoReleasesFound() async throws {
        let domain = "test.check.nil.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, defaults: defaults, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              checkError == .noReleasesFound else {
            Issue.record("Expected .failed(.noReleasesFound), got \(result)")
            return
        }
        #expect(updater.isDownloading == false)
    }

    // MARK: - 2. Provider returns release that is NOT newer → .upToDate

    /// When the provider returns a release whose tag is older than
    /// `currentVersion`, `checkForUpdate` must return `.upToDate`.
    @Test func providerReturnsOlderVersion_upToDate() async throws {
        let domain = "test.check.older.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let provider = MockReleaseProvider(releaseToReturn: release(tag: olderTag))
        let updater = makeUpdater(domain: domain, defaults: defaults, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .upToDate = result else {
            Issue.record("Expected .upToDate, got \(result)")
            return
        }
    }

    // MARK: - 3. Provider returns newer release → .updateAvailable

    /// When the provider returns a release newer than `currentVersion`,
    /// `checkForUpdate` must return `.updateAvailable` with that release.
    @Test func providerReturnsNewerVersion_updateAvailable() async throws {
        let domain = "test.check.newer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let provider = MockReleaseProvider(releaseToReturn: release(tag: newerTag))
        let updater = makeUpdater(domain: domain, defaults: defaults, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .updateAvailable(let r) = result else {
            Issue.record("Expected .updateAvailable, got \(result)")
            return
        }
        #expect(r.tagName == newerTag)
    }

    // MARK: - 4. betaChannel=false forwarded to provider

    /// `checkForUpdate(betaChannel: false)` must pass `false` through to
    /// `provider.fetchLatestRelease`.
    @Test func betaChannelFalse_passedToProvider() async throws {
        let domain = "test.check.beta.false.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, defaults: defaults, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: false)

        let captured = await provider.capturedBetaChannel
        #expect(captured == false)
    }

    // MARK: - 5. betaChannel=true forwarded to provider

    /// `checkForUpdate(betaChannel: true)` must pass `true` through to
    /// `provider.fetchLatestRelease`.
    @Test func betaChannelTrue_passedToProvider() async throws {
        let domain = "test.check.beta.true.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, defaults: defaults, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: true)

        let captured = await provider.capturedBetaChannel
        #expect(captured == true)
    }

    // MARK: - 6. fetchLatestRelease called exactly once per checkForUpdate

    /// `checkForUpdate` must call `fetchLatestRelease` exactly once —
    /// no retry, no double-fetch.
    @Test func callCount_exactlyOnePerCheck() async throws {
        let domain = "test.check.callcount.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, defaults: defaults, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: false)

        let count = await provider.callCount
        #expect(count == 1)
    }
}
