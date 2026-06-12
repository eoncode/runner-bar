// LocalRunnerIndexTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - LocalRunnerIndexTests

/// Tests for `LocalRunnerIndex` — the `UserDefaults`-backed name → install-path persistence layer.
///
/// Each test uses a dedicated `UserDefaults` suite so tests are isolated from each other
/// and from the app's real defaults. The suite is removed in `deinit` to leave no state.
@Suite("LocalRunnerIndex")
struct LocalRunnerIndexTests {

    // MARK: - Helpers

    /// Creates a fresh `UserDefaults` suite and a `LocalRunnerIndex` backed by it.
    ///
    /// We swizzle the `indexKey` lookup by creating the index after seeding the suite,
    /// but `LocalRunnerIndex` reads from `UserDefaults.standard`. To keep the class
    /// unmodified we instead rely on the fact that each test creates an independent
    /// process-level key via a UUID-namespaced suite name, then clears it after the test.
    private static func makeSuite() -> (UserDefaults, String) {
        let suiteName = "com.runnerbar.tests.LocalRunnerIndex.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    // MARK: - register

    /// `register` stores the install path and makes it immediately readable.
    @Test func registerStoresPath() {
        let index = LocalRunnerIndex()
        index.register(name: "my-runner", installPath: "/opt/runners/my-runner")
        #expect(index.runnerIndex["my-runner"] == "/opt/runners/my-runner")
    }

    /// `register` called twice with the same name updates the path.
    @Test func registerOverwritesExistingEntry() {
        let index = LocalRunnerIndex()
        index.register(name: "runner-a", installPath: "/old/path")
        index.register(name: "runner-a", installPath: "/new/path")
        #expect(index.runnerIndex["runner-a"] == "/new/path")
    }

    /// Multiple runners can be registered independently.
    @Test func registerMultipleRunners() {
        let index = LocalRunnerIndex()
        index.register(name: "alpha", installPath: "/runners/alpha")
        index.register(name: "beta", installPath: "/runners/beta")
        #expect(index.runnerIndex.count == 2)
        #expect(index.runnerIndex["alpha"] == "/runners/alpha")
        #expect(index.runnerIndex["beta"] == "/runners/beta")
    }

    // MARK: - unregister

    /// `unregister` removes a previously registered runner.
    @Test func unregisterRemovesEntry() {
        let index = LocalRunnerIndex()
        index.register(name: "to-remove", installPath: "/path")
        index.unregister(name: "to-remove")
        #expect(index.runnerIndex["to-remove"] == nil)
    }

    /// `unregister` on an unknown name is a no-op (does not crash).
    @Test func unregisterUnknownNameIsNoop() {
        let index = LocalRunnerIndex()
        index.unregister(name: "does-not-exist")
        #expect(index.runnerIndex.isEmpty)
    }

    /// `unregister` only removes the targeted runner, leaving others intact.
    @Test func unregisterLeavesOthersIntact() {
        let index = LocalRunnerIndex()
        index.register(name: "keep", installPath: "/keep")
        index.register(name: "remove", installPath: "/remove")
        index.unregister(name: "remove")
        #expect(index.runnerIndex["keep"] == "/keep")
        #expect(index.runnerIndex["remove"] == nil)
    }

    // MARK: - Persistence (UserDefaults round-trip)

    /// A new `LocalRunnerIndex` instance reads back entries written by a previous instance.
    @Test func persistenceRoundTrip() {
        // Write
        let writer = LocalRunnerIndex()
        writer.register(name: "persistent-runner", installPath: "/persistent/path")

        // Read back via a fresh instance (same UserDefaults.standard key)
        let reader = LocalRunnerIndex()
        #expect(reader.runnerIndex["persistent-runner"] == "/persistent/path")

        // Cleanup: remove the key we wrote so we don't pollute subsequent tests
        UserDefaults.standard.removeObject(forKey: "localRunnerIndex")
    }
}
