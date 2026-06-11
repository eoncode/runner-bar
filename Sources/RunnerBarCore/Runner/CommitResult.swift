// CommitResult.swift
// RunnerBarCore
// Moved from RunnerBar app target to RunnerBarCore in Phase 5 (#1300).
import Foundation

// MARK: - CommitResult

/// The outcome of a `SaveRunnerEditsUseCase.execute` call.
public enum CommitResult: Equatable {
    /// All requested writes succeeded.
    case success
    /// One or more writes failed. `errors` contains human-readable messages.
    case failure([String])
}
