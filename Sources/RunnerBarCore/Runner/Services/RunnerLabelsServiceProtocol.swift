// RunnerLabelsServiceProtocol.swift
// RunBotCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation

// MARK: - RunnerLabelsService

/// Abstraction over the `patchRunnerLabels` network call.
///
/// Inject a test double in unit tests; use `DefaultRunnerLabelsService` in production.
///
/// **Return type note:** `patch` returns `[String]?` (the updated label names from the
/// GitHub API response) rather than the `Bool` in the original issue spec. This is an
/// intentional upgrade — the richer return value lets callers inspect the persisted
/// label set without an extra network round-trip, and `nil` still unambiguously signals
/// failure, which is all `SaveRunnerEditsUseCase.execute` needs to check.
public protocol RunnerLabelsService: Sendable {
    /// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`.
    ///
    /// - Returns: The updated label names as confirmed by the GitHub API on success,
    ///   or `nil` on any API failure. The caller should treat `nil` as a hard failure
    ///   and abort the commit transaction.
    func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]?
}
