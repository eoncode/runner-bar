// RunnerProxyStoreProtocol.swift
// RunnerBarCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation

// MARK: - RunnerProxyStoreProtocol

/// Abstraction over `RunnerProxyStore` that enables test doubles.
///
/// `RunnerProxyStore` conforms to this protocol. Inject a spy in unit tests;
/// pass `RunnerProxyStore.shared` in production.
public protocol RunnerProxyStoreProtocol: Sendable {
    /// Reads `.proxy` and `.proxycredentials` at `installPath`.
    /// Non-throwing: returns a zeroed config when files are absent.
    func load(at installPath: String) async -> RunnerProxyConfig
    /// Writes (or removes) `.proxy` and `.proxycredentials` at `installPath`.
    func save(_ config: RunnerProxyConfig, at installPath: String) async throws(RunnerProxyStoreError)
}
