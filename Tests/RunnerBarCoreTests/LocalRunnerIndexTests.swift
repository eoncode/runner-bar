// LocalRunnerIndexTests.swift
// RunnerBarCoreTests
import Foundation
import Testing
@testable import RunnerBarCore

// MARK: - LocalRunnerIndexTests

/// Tests for `LocalRunnerIndex` — the `UserDefaults`-backed name → install-path persistence layer.
///
/// Every test clears `UserDefaults.standard` key `"localRunnerIndex"` via `defer` so
/// tests are fully isolated from each other and from the host app’s real defaults.
@Suite("LocalRunnerIndex")
struct LocalRunnerIndexTests {

    // MARK: - register

    /// `register` stores the install path and makes it immediately readable.
    @Test func registerStoresPath() {
        defer { UserDefaults.standard.removeObject(forKey: "localRunnerIndex") }
        let index = LocalRunnerIndex()
        index.register(name: "my-runner", installPath: "/opt/runners/my-runner")
        #expect(index.runnerIndex["my-runner"] == "/opt/runners/my-runner")
    }

    /// `register` called twice with the same name updates the path.
    @Test func registerOverwritesExistingEntry() {
        defer { UserDefaults.standard.removeObject(forKey: "localRunnerIndex") }
        let index = LocalRunnerIndex()
        index.register(name: "runner-a", installPath: "/old/path")
        index.register(name: "runner-a", installPath: "/new/path")
        #expect(index.runnerIndex["runner-a"] == "/new/path")
    }

    /// Multiple runners can be registered independently.
    @Test func registerMultipleRunners() {
        defer { UserDefaults.standard.removeObject(forKey: "localRunnerIndex") }
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
        defer { UserDefaults.standard.removeObject(forKey: "localRunnerIndex") }
        let index = LocalRunnerIndex()
        index.register(name: "to-remove", installPath: "/path")
        index.unregister(name: "to-remove")
        #expect(index.runnerIndex["to-remove"] == nil)
    }

    /// `unregister` on an unknown name is a no-op (does not crash).
    @Test func unregisterUnknownNameIsNoop() {
        defer { UserDefaults.standard.removeObject(forKey: "localRunnerIndex") }
        let index = LocalRunnerIndex()
        index.unregister(name: "does-not-exist")
        #expect(index.runnerIndex.isEmpty)
    }

    /// `unregister` only removes the targeted runner, leaving others intact.
    @Test func unregisterLeavesOthersIntact() {
        defer { UserDefaults.standard.removeObject(forKey: "localRunnerIndex") }
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
        defer { UserDefaults.standard.removeObject(forKey: "localRunnerIndex") }
        let writer = LocalRunnerIndex()
        writer.register(name: "persistent-runner", installPath: "/persistent/path")
        let reader = LocalRunnerIndex()
        #expect(reader.runnerIndex["persistent-runner"] == "/persistent/path")
    }
}
