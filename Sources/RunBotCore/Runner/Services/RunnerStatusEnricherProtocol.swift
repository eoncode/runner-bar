// RunnerStatusEnricherProtocol.swift
// RunBotCore
// Phase 6b of the Swift 6.2 data model modernisation (#1287, #1326).
import Foundation

// MARK: - RunnerStatusEnricherProtocol

/// Abstraction over GitHub runner-status enrichment.
///
/// Introduced in Phase 6b (#1326) so that `LocalRunnerStore` can depend on an
/// injected enricher instead of calling `RunnerStatusEnricher.shared` directly,
/// making `LocalRunnerStore.performRefresh()` unit-testable with a stub.
///
/// ## Production usage
/// ```swift
/// LocalRunnerStore(viewModel: vm, enricher: RunnerStatusEnricher.shared)
/// ```
///
/// ## Test double
/// ```swift
/// struct StubEnricher: RunnerStatusEnricherProtocol {
///     func enrich(runners: [RunnerModel]) async -> [RunnerModel] { runners }
/// }
/// ```
///
/// - Note: `Sendable` conformance is required so the existential can be stored as
///   a `private let` inside `LocalRunnerStore` (a Swift 6 `actor`) without
///   triggering non-Sendable-capture warnings at the actor boundary.
public protocol RunnerStatusEnricherProtocol: Sendable {
    /// Enriches the given runners with live GitHub API data (status, busy, labels,
    /// runner group) and returns the updated array.
    ///
    /// - Parameter runners: The locally-discovered runner list to enrich.
    /// - Returns: A new array with the same runners, each enriched where an API
    ///   match was found. Runners with no `gitHubUrl` are returned unchanged.
    func enrich(runners: [RunnerModel]) async -> [RunnerModel]
}
