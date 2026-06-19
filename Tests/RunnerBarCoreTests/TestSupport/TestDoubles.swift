// TestDoubles.swift
// RunnerBarCoreTests
// Shared test doubles — extracted per #1447.
import Foundation
import RunnerBarCore

// MARK: - SpyLabelsService

/// Spy conformance for `RunnerLabelsService`.
///
/// Implemented as an `actor` so Swift's compiler enforces isolation without
/// requiring `@unchecked Sendable`. The `result` and recorded-call properties
/// are accessed from the test body before/after `execute(...)` — never concurrently.
actor SpyLabelsService: RunnerLabelsService {
    // Note: defaults to [] (empty array), not nil — tests that don't call setUp will
    // silently receive an empty label list rather than a failure. Configure via setUp(result:).
    private var result: [String]? = []
    private(set) var callCount = 0
    private(set) var lastScope: String?
    private(set) var lastRunnerID: Int?
    private(set) var lastLabels: [String]?

    /// Configures the value returned by `patch(...)`. Call from the test body before `execute`.
    func setUp(result: [String]?) { self.result = result }

    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]? {
        callCount += 1
        lastScope = scope
        lastRunnerID = runnerID
        lastLabels = labels
        return result
    }
}

// MARK: - SpyConfigStore

/// Spy conformance for `RunnerConfigStoreProtocol`.
///
/// Implemented as an `actor` — see `SpyLabelsService` for rationale.
actor SpyConfigStore: RunnerConfigStoreProtocol {
    var loadResult: RunnerConfig = RunnerConfig(workFolder: "_work", disableUpdate: false)
    private var shouldThrowOnSave = false
    private(set) var saveCalled = false
    private(set) var savedConfig: RunnerConfig?

    /// Configures whether `save(...)` throws. Call from the test body before `execute`.
    func setUp(shouldThrowOnSave: Bool) { self.shouldThrowOnSave = shouldThrowOnSave }

    func load(at _: String) async throws(RunnerConfigStoreError) -> RunnerConfig { loadResult }
    func save(_ config: RunnerConfig, at installPath: String) async throws(RunnerConfigStoreError) {
        if shouldThrowOnSave { throw RunnerConfigStoreError.writeFailed(installPath, TestError.saveFailed) }
        saveCalled = true
        savedConfig = config
    }
}

// MARK: - SpyProxyStore

/// Spy conformance for `RunnerProxyStoreProtocol`.
///
/// Implemented as an `actor` — see `SpyLabelsService` for rationale.
actor SpyProxyStore: RunnerProxyStoreProtocol {
    private var shouldThrowOnSave = false
    private(set) var saveCalled = false
    private(set) var savedConfig: RunnerProxyConfig?

    /// Configures whether `save(...)` throws. Call from the test body before `execute`.
    func setUp(shouldThrowOnSave: Bool) { self.shouldThrowOnSave = shouldThrowOnSave }

    func load(at _: String) async -> RunnerProxyConfig { RunnerProxyConfig() }
    func save(_ config: RunnerProxyConfig, at installPath: String) async throws(RunnerProxyStoreError) {
        if shouldThrowOnSave { throw RunnerProxyStoreError.writeFailed(["spy: save not allowed"]) }
        saveCalled = true
        savedConfig = config
    }
}

// MARK: - HookCounter

/// Actor-isolated counter for tracking fireFailureHook call counts in async tests.
actor HookCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - TestError

enum TestError: Error { case saveFailed }
