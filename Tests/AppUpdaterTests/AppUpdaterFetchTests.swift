// AppUpdaterFetchTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterFetchTests

/// Tests that verify `AppUpdater.checkAndHandle` drives host state correctly
/// based on what `MockReleaseProvider` returns.
///
/// Zero `DispatchQueue` usage (Pillar 5). All tests run on `@MainActor`
/// because `AppUpdater` and `MockUpdateState` are both `@MainActor`.
@MainActor
struct AppUpdaterFetchTests {

    // MARK: - Helpers

    /// Returns a fresh `AppUpdater` + `MockReleaseProvider` + `MockUpdateState`
    /// triple. The updater uses an isolated `UserDefaults` domain so tests
    /// never pollute `.standard`.
    private func makeStack(
        currentVersion: String = "1.0.0",
        betaChannel: Bool = false
    ) -> (updater: AppUpdater, provider: MockReleaseProvider, state: MockUpdateState) {
        let provider = MockReleaseProvider()
        let state = MockUpdateState()
        let defaults = UserDefaults(suiteName: "AppUpdaterFetchTests.\(UUID().uuidString)")!
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.fetch.\(UUID().uuidString)",
            userDefaults: defaults,
            betaChannelProvider: { betaChannel },
            releaseProvider: provider
        )
        return (updater, provider, state)
    }

    private func makeRelease(
        tagName: String = "v2.0.0",
        prerelease: Bool = false
    ) -> AvailableRelease {
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: URL(string: "https://example.com/App.zip")!
        )
        return AvailableRelease(tagName: tagName, assets: [asset], checksumURL: nil)
    }

    // MARK: - Tests

    @Test func checkAndHandle_updateAvailable_callsSetAvailableUpdate() async throws {
        let (updater, provider, state) = makeStack()
        provider.fetchResult = .success(makeRelease())
        await updater.checkAndHandle(state: state)
        #expect(!state.availableUpdates.isEmpty)
    }

    @Test func checkAndHandle_upToDate_noStateTransition() async throws {
        // Provider returns the *same* version — isNewer returns false → .upToDate
        let (updater, provider, state) = makeStack(currentVersion: "2.0.0")
        provider.fetchResult = .success(makeRelease(tagName: "v2.0.0"))
        await updater.checkAndHandle(state: state)
        #expect(state.availableUpdates.isEmpty)
        #expect(state.downloadStartedCount == 0)
    }

    @Test func checkAndHandle_nilRelease_noStateTransition() async throws {
        let (updater, provider, state) = makeStack()
        provider.fetchResult = .success(nil)
        await updater.checkAndHandle(state: state)
        #expect(state.availableUpdates.isEmpty)
        #expect(state.downloadStartedCount == 0)
    }

    @Test func checkAndHandle_betaOff_prereleaseIgnored() async throws {
        // betaChannel = false, provider returns a pre-release tag
        let (updater, provider, state) = makeStack(betaChannel: false)
        // Provider returns the beta release, but AppUpdater will call
        // fetchLatestRelease(betaChannel: false) — MockReleaseProvider just
        // returns whatever fetchResult is set to regardless of betaChannel;
        // the real filtering lives in GitHubReleaseProvider. Here we test the
        // wiring: capturedBetaChannel must be false.
        provider.fetchResult = .success(makeRelease(tagName: "v2.0.0-beta.1", prerelease: true))
        await updater.checkAndHandle(state: state)
        let captured = await provider.capturedBetaChannel
        #expect(captured == false)
    }

    @Test func checkAndHandle_betaOn_prereleaseOffered() async throws {
        let (updater, provider, state) = makeStack(betaChannel: true)
        provider.fetchResult = .success(makeRelease(tagName: "v2.0.0-beta.1", prerelease: true))
        await updater.checkAndHandle(state: state)
        let captured = await provider.capturedBetaChannel
        #expect(captured == true)
        #expect(!state.availableUpdates.isEmpty)
    }

    @Test func checkAndHandle_fetchCallCount_exactlyOne() async throws {
        let (updater, provider, state) = makeStack()
        provider.fetchResult = .success(nil)
        await updater.checkAndHandle(state: state)
        let count = await provider.fetchCallCount
        #expect(count == 1)
        _ = state // silence unused warning
    }
}
