// RunnerConfigStoreProtocol.swift
// RunnerBarCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation

// MARK: - RunnerConfigStoreProtocol

/// Abstraction over `RunnerConfigStore` that enables test doubles.
///
/// `RunnerConfigStore` conforms to this protocol. Inject a spy in unit tests;
/// pass `RunnerConfigStore.shared` in production.
public protocol RunnerConfigStoreProtocol: Sendable {
    /// Loads the typed runner config from `installPath/.runner`.
    func load(at installPath: String) async throws -> RunnerConfig
    /// Saves the typed runner config to `installPath/.runner`.
    func save(_ config: RunnerConfig, at installPath: String) async throws
}
