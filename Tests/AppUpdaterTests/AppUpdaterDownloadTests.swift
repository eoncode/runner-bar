// AppUpdaterDownloadTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterDownloadTests

/// Tests that verify `AppUpdater.handle` download-path state-machine behaviour.
///
/// Network I/O is avoided: a release with a nil checksumURL exercises the
/// step-2 early-exit path in `handle()` without hitting a real server.
/// All tests are `@MainActor` because `AppUpdater` and `MockUpdateState`
/// are both `@MainActor`.
@MainActor
struct AppUpdaterDownloadTests {

    // MARK: - Helpers

    private func makeUpdater(
        currentVersion: String = "1.0.0"
    ) throws -> (updater: AppUpdater, state: MockUpdateState, defaults: UserDefaults) {
        let domain = "AppUpdaterDownloadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain,
            userDefaults: defaults,
            betaChannelProvider: { false }
        )
        return (updater, MockUpdateState(), defaults)
    }

    /// Makes an `AvailableRelease` where `checksumURL` is `nil`.
    ///
    /// `handle()` guards on a nil `checksumURL` in step 2 (before entering the
    /// download path) and calls `setAssetMissing()`. No `Task` is spawned and
    /// `setDownloadStarted()` / `setUpdateFailed()` are never called. This is
    /// the fastest failure path and exercises the step-2 early-exit without
    /// any network activity.
    private func releaseWithNilChecksum(tagName: String = "v2.0.0") throws -> AvailableRelease {
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        return AvailableRelease(tagName: tagName, assets: [asset], checksumURL: nil)
    }

    // MARK: - Tests

    /// A nil `checksumURL` is caught in `handle()` step 2 and routed to
    /// `setAssetMissing()` — the download path is never entered so
    /// `setUpdateFailed()` must NOT be called.
    @Test func downloadError_nilChecksumURL_setsAssetMissing() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        #expect(state.assetMissingCount == 1)
        #expect(state.updateFailedCount == 0)
        #expect(updater.isDownloading == false)
    }

    /// After a nil-checksumURL early exit `isDownloading` must be `false` —
    /// regression guard for the stuck-state bug where it stays `true` and
    /// every subsequent `handle()` silently no-ops via the in-flight guard.
    @Test func downloadError_clearsIsDownloadingFlag() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        #expect(updater.isDownloading == false)
        _ = state
    }

    /// A nil `checksumURL` must call `setAssetMissing()`, NOT
    /// `setDownloadComplete()` or `setUpdateFailed()`.
    @Test func checksumURLNil_setsAssetMissing_notDownloadComplete() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        #expect(state.assetMissingCount == 1)
        #expect(state.updateFailedCount == 0)
        #expect(state.downloadCompleteCount == 0)
    }

    /// While `isDownloading` is already `true`, a second `handle()` call for a
    /// downloadable release must be dropped entirely: `downloadStartedCount`
    /// on the state is not incremented again.
    @Test func concurrentHandle_secondDropped_whenIsDownloadingTrue() async throws {
        let (updater, state, _) = try makeUpdater()
        updater.isDownloading = true   // simulate an in-flight download
        await updater.handle(try releaseWithNilChecksum(), state: state)
        #expect(state.downloadStartedCount == 0)
        #expect(state.updateFailedCount == 0)
    }

    /// `handle()` step 2 exits via `setAssetMissing()` when `checksumURL` is
    /// nil — the download path is never entered so `setDownloadStarted()` must
    /// NOT be called.
    @Test func nilChecksumURL_doesNotCallSetDownloadStarted() async throws {
        let (updater, state, _) = try makeUpdater()
        await updater.handle(try releaseWithNilChecksum(), state: state)
        // step-2 early exit fires synchronously; no Task is spawned.
        #expect(state.downloadStartedCount == 0)
        #expect(state.assetMissingCount == 1)
    }
}
