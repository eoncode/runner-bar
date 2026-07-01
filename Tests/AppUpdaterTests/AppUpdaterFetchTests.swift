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

    private func makeStack(
        currentVersion: String = "1.0.0",
        betaChannel: Bool = false
    ) throws -> (updater: AppUpdater, provider: MockReleaseProvider, state: MockUpdateState) {
        let provider = MockReleaseProvider()
        let state = MockUpdateState()
        let domain = "AppUpdaterFetchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain,
            userDefaults: defaults,
            betaChannelProvider: { betaChannel },
            releaseProvider: provider
        )
        return (updater, provider, state)
    }

    private func makeRelease(
        tagName: String = "v2.0.0"
    ) throws -> AvailableRelease {
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        return AvailableRelease(tagName: tagName, assets: [asset], checksumURL: nil)
    }

    // MARK: - Tests

    @Test func checkAndHandle_updateAvailable_callsSetAvailableUpdate() async throws {
        let (updater, provider, state) = try makeStack()
        await provider.set(releaseToReturn: try makeRelease())
        await updater.checkAndHandle(state: state)
        #expect(!state.availableUpdates.isEmpty)
    }

    @Test func checkAndHandle_upToDate_noStateTransition() async throws {
        // Provider returns the same version as currentVersion → .upToDate
        let (updater, provider, state) = try makeStack(currentVersion: "2.0.0")
        await provider.set(releaseToReturn: try makeRelease(tagName: "v2.0.0"))
        await updater.checkAndHandle(state: state)
        #expect(state.availableUpdates.isEmpty)
        #expect(state.downloadStartedCount == 0)
    }

    @Test func checkAndHandle_nilRelease_noStateTransition() async throws {
        let (updater, _, state) = try makeStack()
        // Default releaseToReturn is nil — no mutation expected
        await updater.checkAndHandle(state: state)
        #expect(state.availableUpdates.isEmpty)
        #expect(state.downloadStartedCount == 0)
    }

    @Test func checkAndHandle_betaOff_capturedBetaChannelIsFalse() async throws {
        let (updater, provider, state) = try makeStack(betaChannel: false)
        await provider.set(releaseToReturn: nil)
        await updater.checkAndHandle(state: state)
        let captured = await provider.capturedBetaChannel
        #expect(captured == false)
        _ = state
    }

    @Test func checkAndHandle_betaOn_capturedBetaChannelIsTrue() async throws {
        let (updater, provider, state) = try makeStack(betaChannel: true)
        await provider.set(releaseToReturn: try makeRelease(tagName: "v2.0.0-beta.1"))
        await updater.checkAndHandle(state: state)
        let captured = await provider.capturedBetaChannel
        #expect(captured == true)
        #expect(!state.availableUpdates.isEmpty)
    }

    @Test func checkAndHandle_fetchCallCount_exactlyOne() async throws {
        let (updater, provider, state) = try makeStack()
        await updater.checkAndHandle(state: state)
        let count = await provider.fetchCallCount
        #expect(count == 1)
        _ = state
    }
}
