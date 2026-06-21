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
///
/// Storage format: JSON-encoded `[String: String]` stored as `Data` under `indexKey`.
/// One-time migration: if the key holds a legacy `NSPropertyList` dictionary (pre-Codable),
/// it is decoded via `NSDictionary` cast and immediately re-persisted as JSON.
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
    /// Throws if stored data exists but cannot be decoded (surfaces malformed data
    /// instead of silently returning an empty index).
    public init(defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        try loadIndex()
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
    ///
    /// Decode order:
    /// 1. If the key holds `Data`, decode as JSON `[String: String]`.
    /// 2. If the key holds a legacy `NSDictionary` (pre-Codable plist format),
    ///    cast it and immediately re-persist as JSON (one-time migration).
    /// 3. If the key is absent, start with an empty index.
    ///
    /// Throws `DecodingError` when stored `Data` exists but is malformed.
    private func loadIndex() throws {
        if let data = defaults.data(forKey: Self.indexKey) {
            // New Codable path.
            runnerIndex = try JSONDecoder().decode([String: String].self, from: data)
            log("LocalRunnerIndex › loadIndex — \(runnerIndex.count) entry(ies): \(runnerIndex.keys.sorted())")
        } else if let legacy = defaults.dictionary(forKey: Self.indexKey) as? [String: String] {
            // One-time migration from legacy NSPropertyList dict → JSON Data.
            runnerIndex = legacy
            persistIndex()
            log("LocalRunnerIndex › loadIndex — migrated \(runnerIndex.count) legacy plist entry(ies) to JSON")
        } else {
            runnerIndex = [:]
            log("LocalRunnerIndex › loadIndex — no data found, starting empty")
        }
    }

    /// JSON-encodes and writes the current `runnerIndex` to `UserDefaults`.
    private func persistIndex() {
        do {
            let data = try JSONEncoder().encode(runnerIndex)
            defaults.set(data, forKey: Self.indexKey)
            log("LocalRunnerIndex › persistIndex — \(runnerIndex.count) entry(ies) written")
        } catch {
            log("LocalRunnerIndex › persistIndex — encode failed: \(error)")
        }
    }
}
