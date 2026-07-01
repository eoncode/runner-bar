// AppUpdaterDefaultsTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterDefaultsTests

/// Tests that verify the `UserDefaults` key scoping, `clearCachedDefaults()`
/// logic, and `rehydrateCachedUpdateIfNewer` round-trip behaviour.
///
/// All tests run against isolated `UserDefaults` suites (never `.standard`).
/// No async, no network, no `DispatchQueue` (Pillar 5).
@MainActor
struct AppUpdaterDefaultsTests {

    // MARK: - Helpers

    private func makeUpdater(
        currentVersion: String = "1.0.0"
    ) throws -> (updater: AppUpdater, keys: AppUpdaterDefaults, defaults: UserDefaults, domain: String) {
        let domain = "AppUpdaterDefaultsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let keys = AppUpdaterDefaults(domain: domain)
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain,
            userDefaults: defaults,
            betaChannelProvider: { false }
        )
        return (updater, keys, defaults, domain)
    }

    // MARK: - Key scoping

    @Test func defaultsKeys_scopedToDomain() {
        let domain = "com.test.keyscoping"
        let keys = AppUpdaterDefaults(domain: domain)
        #expect(keys.cachedUpdateZipPath == "\(domain).cachedUpdateZipPath")
        #expect(keys.cachedUpdateVersion == "\(domain).cachedUpdateVersion")
    }

    @Test func twoDistinctDomains_produceDistinctKeys() {
        let a = AppUpdaterDefaults(domain: "com.test.a")
        let b = AppUpdaterDefaults(domain: "com.test.b")
        #expect(a.cachedUpdateZipPath != b.cachedUpdateZipPath)
        #expect(a.cachedUpdateVersion != b.cachedUpdateVersion)
    }

    // MARK: - clearCachedDefaults

    @Test func clearCachedDefaults_removesPersistedKeys() throws {
        let (updater, keys, defaults, domain) = try makeUpdater()
        defer { defaults.removePersistentDomain(forName: domain) }
        // Write values manually as if a prior download completed.
        defaults.set("/tmp/test.zip", forKey: keys.cachedUpdateZipPath)
        defaults.set("v2.0.0", forKey: keys.cachedUpdateVersion)
        // Trigger clear via rehydrateCachedUpdateIfNewer with a missing file
        // path — the file does not exist, so the clear branch fires.
        let state = MockUpdateState()
        updater.rehydrateCachedUpdateIfNewer(state: state)
        #expect(defaults.string(forKey: keys.cachedUpdateZipPath) == nil)
        #expect(defaults.string(forKey: keys.cachedUpdateVersion) == nil)
    }

    // MARK: - Rehydrate round-trip

    @Test func rehydrate_existingFileNewerVersion_setsStateCorrectly() throws {
        let (updater, keys, defaults, domain) = try makeUpdater(currentVersion: "1.0.0")
        defer { defaults.removePersistentDomain(forName: domain) }
        // Write a real temp file.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rehydrate-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        defaults.set(tmp.path, forKey: keys.cachedUpdateZipPath)
        defaults.set("v2.0.0", forKey: keys.cachedUpdateVersion)
        let state = MockUpdateState()
        updater.rehydrateCachedUpdateIfNewer(state: state)
        #expect(state.rehydrateCount == 1)
        #expect(state.updateZipURL == tmp)
        #expect(state.cachedUpdateVersion == "v2.0.0")
        #expect(!state.availableUpdates.isEmpty)
    }

    @Test func rehydrate_fileExistsButVersionNotNewer_clearsKeys() throws {
        let (updater, keys, defaults, domain) = try makeUpdater(currentVersion: "2.0.0")
        defer { defaults.removePersistentDomain(forName: domain) }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rehydrate-old-\(UUID().uuidString).zip")
        try Data("zip".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        defaults.set(tmp.path, forKey: keys.cachedUpdateZipPath)
        defaults.set("v1.0.0", forKey: keys.cachedUpdateVersion)
        let state = MockUpdateState()
        updater.rehydrateCachedUpdateIfNewer(state: state)
        #expect(state.rehydrateCount == 0)
        #expect(defaults.string(forKey: keys.cachedUpdateZipPath) == nil)
        #expect(defaults.string(forKey: keys.cachedUpdateVersion) == nil)
    }

    @Test func rehydrate_noKeysWritten_noStateTransition() throws {
        let (updater, _, defaults, domain) = try makeUpdater()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = MockUpdateState()
        updater.rehydrateCachedUpdateIfNewer(state: state)
        #expect(state.rehydrateCount == 0)
        #expect(state.availableUpdates.isEmpty)
    }

    // MARK: - checkInterval (DEBUG only)

    #if DEBUG
    @Test func checkInterval_debug_defaultIs60Seconds() {
        #expect(AppUpdaterDefaults.checkInterval == 60)
    }
    #endif
}
