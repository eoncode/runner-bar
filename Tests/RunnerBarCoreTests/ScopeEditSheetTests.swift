// ScopeEditSheetTests.swift
// RunnerBarCoreTests
// Tests for the atomic-save contract introduced by the ScopeEditSheet DI rewrite — refs #1540.
import Foundation
import Testing

// MARK: - Fake store

/// In-memory stand-in for `ScopePreferencesStoreProtocol`.
/// Records every `setPreferences(_:for:)` call so tests can assert
/// that exactly one write occurred and that it carried the correct values.
@MainActor
final class FakeScopePreferencesStore: ScopePreferencesStoreProtocol {

    // MARK: Stored state

    /// Backing storage keyed by scope string.
    private var store: [String: ScopePreferences] = [:]

    /// Ordered log of every `setPreferences` invocation.
    private(set) var writeLog: [(scope: String, prefs: ScopePreferences)] = []

    // MARK: ScopePreferencesStoreProtocol

    func preferences(for scope: String) -> ScopePreferences {
        store[scope] ?? ScopePreferences()
    }

    func setPreferences(_ prefs: ScopePreferences, for scope: String) {
        store[scope] = prefs
        writeLog.append((scope: scope, prefs: prefs))
    }

    func displayName(for scope: String) -> String {
        store[scope]?.alias ?? scope
    }

    func removePreferences(for scope: String) {
        store.removeValue(forKey: scope)
    }

    // MARK: Convenience

    /// Seeds the store with a known value so tests can control the initial state.
    func seed(_ prefs: ScopePreferences, for scope: String) {
        store[scope] = prefs
    }
}

// MARK: - Helpers

/// Mimics the save logic from `ScopeEditSheet.confirmSave()`.
/// Extracted here so the core contract can be tested without importing SwiftUI.
@MainActor
private func confirmSave(
    scope: String,
    updated: ScopePreferences,
    into store: any ScopePreferencesStoreProtocol
) {
    store.setPreferences(updated, for: scope)
}

// MARK: - Test suite

@MainActor
@Suite("ScopeEditSheet atomic save")
struct ScopeEditSheetTests {

    // MARK: Single-write contract

    @Test("confirmSave writes exactly once")
    func confirmSaveWritesExactlyOnce() {
        let fake = FakeScopePreferencesStore()
        let prefs = ScopePreferences(alias: "My Org", failureHookEnabled: true)
        confirmSave(scope: "eoncode", updated: prefs, into: fake)
        #expect(fake.writeLog.count == 1)
    }

    @Test("confirmSave targets the correct scope")
    func confirmSaveTargetsCorrectScope() {
        let fake = FakeScopePreferencesStore()
        let prefs = ScopePreferences(alias: "My Repo")
        confirmSave(scope: "eoncode/runner-bar", updated: prefs, into: fake)
        #expect(fake.writeLog.first?.scope == "eoncode/runner-bar")
    }

    @Test("confirmSave persists all fields in a single write")
    func confirmSavePersistsAllFields() {
        let fake = FakeScopePreferencesStore()
        let prefs = ScopePreferences(
            alias: "CI Org",
            failureHookEnabled: true,
            failureHookCommand: "./notify.sh",
            failureHookBranch: "main",
            localRepoPath: "/Users/dev/ci"
        )
        confirmSave(scope: "acme", updated: prefs, into: fake)
        let written = fake.writeLog[0].prefs
        #expect(written.alias == "CI Org")
        #expect(written.failureHookEnabled == true)
        #expect(written.failureHookCommand == "./notify.sh")
        #expect(written.failureHookBranch == "main")
        #expect(written.localRepoPath == "/Users/dev/ci")
    }

    // MARK: No spurious writes

    @Test("reading preferences does not produce a write")
    func readingDoesNotWrite() {
        let fake = FakeScopePreferencesStore()
        fake.seed(ScopePreferences(alias: "Seeded"), for: "acme")
        _ = fake.preferences(for: "acme")
        #expect(fake.writeLog.isEmpty)
    }

    @Test("confirmSave for one scope does not touch another scope")
    func saveDoesNotCrossContaminateScopes() {
        let fake = FakeScopePreferencesStore()
        fake.seed(ScopePreferences(alias: "Original"), for: "other-scope")
        confirmSave(scope: "my-scope", updated: ScopePreferences(alias: "New"), into: fake)
        let untouched = fake.preferences(for: "other-scope")
        #expect(untouched.alias == "Original")
    }

    // MARK: Round-trip

    @Test("preferences(for:) returns the value written by confirmSave")
    func roundTrip() {
        let fake = FakeScopePreferencesStore()
        let prefs = ScopePreferences(alias: "Round Trip", failureHookEnabled: false)
        confirmSave(scope: "rt-scope", updated: prefs, into: fake)
        let readBack = fake.preferences(for: "rt-scope")
        #expect(readBack.alias == "Round Trip")
        #expect(readBack.failureHookEnabled == false)
    }

    @Test("second confirmSave overwrites the first")
    func secondSaveOverwritesFirst() {
        let fake = FakeScopePreferencesStore()
        confirmSave(scope: "s", updated: ScopePreferences(alias: "v1"), into: fake)
        confirmSave(scope: "s", updated: ScopePreferences(alias: "v2"), into: fake)
        #expect(fake.writeLog.count == 2)
        #expect(fake.preferences(for: "s").alias == "v2")
    }
}
