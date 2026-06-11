// RunnerStatusEnricherProtocol.swift
// RunnerBarCore

import Foundation

// MARK: - RunnerStatusEnricherProtocol

/// Abstraction over runner-status enrichment, introduced in Phase 6b (#1326).
///
/// Allows `LocalRunnerStore` to depend on an injected enricher instead of
/// calling `RunnerStatusEnricher.shared` directly, making
/// `LocalRunnerStore.performRefresh()` unit-testable with a stub.
///
/// ## Conformance
/// ```swift
/// extension RunnerStatusEnricher: RunnerStatusEnricherProtocol {}
/// ```
///
/// ## Test doubles
/// ```swift
/// struct StubEnricher: RunnerStatusEnricherProtocol {
///     func enrich(runners: [Runner]) async -> [Runner] { runners }
/// }
/// ```
///
/// - Note: Marked `Sendable` so the existential can be stored as a `let`
///   inside `LocalRunnerStore` (an `actor`) without triggering Swift 6's
///   non-Sendable-capture warnings.
public protocol RunnerStatusEnricherProtocol: Sendable {
    /// Enriches the given runners with live GitHub status and returns
    /// the updated array.
    func enrich(runners: [Runner]) async -> [Runner]
}
