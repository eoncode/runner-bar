// LocalRunnerIndex.swift
// RunnerBarCore

import Foundation

// MARK: - LocalRunnerIndex

/// Owns the `UserDefaults`-backed name → install-path index for locally-registered runners.
///
/// Pure persistence layer with no knowledge of the runner model — easily unit-testable in isolation.
/// Non-isolated: owned exclusively by the `LocalRunnerStore` actor, which serializes all access.
/// `UserDefaults` read/write of individual keys is thread-safe; this class uses no KVO or
/// change notifications on `UserDefaults`, so no main-actor coordination is required.
public final class LocalRunnerIndex {

    // MARK: - Storage key

    /// The `UserDefaults` key used to persist the runner name → install path index.
    private static let indexKey = "localRunnerIndex"

    // MARK: - State

    /// Maps runnerName → installPath, persisted to `UserDefaults`.
    public private(set) var runnerIndex: [String: String] = [:]

    // MARK: - Init

    /// The `UserDefaults` store used for persistence. Defaults to `.standard`; injectable for tests.
    private let defaults: UserDefaults

    /// Initialises the index and loads the persisted entries from `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadIndex()
    }

    // MARK: - Mutations

    /// Adds or updates the index entry for `name`, mapping it to `installPath`, then persists.
    public func register(name: String, installPath: String) {
        log("LocalRunnerIndex › register — '\(name)' at \(installPath) (was: \(String(describing: runnerIndex[name])))")
        runnerIndex[name] = installPath
        persistIndex()
    }

    /// Removes `name` from the persisted index.
    public func unregister(name: String) {
        log("LocalRunnerIndex › unregister '\(name)'")
        runnerIndex.removeValue(forKey: name)
        persistIndex()
    }

    // MARK: - Private helpers

    /// Hydrates `runnerIndex` from `UserDefaults` at init time.
    private func loadIndex() {
        runnerIndex = defaults
            .dictionary(forKey: Self.indexKey) as? [String: String] ?? [:]
        log("LocalRunnerIndex › loadIndex — \(runnerIndex.count) entry(ies): \(runnerIndex.keys.sorted())")
    }

    /// Writes the current `runnerIndex` to `UserDefaults`.
    private func persistIndex() {
        defaults.set(runnerIndex, forKey: Self.indexKey)
        log("LocalRunnerIndex › persistIndex — \(runnerIndex.count) entry(ies) written")
    }
}
