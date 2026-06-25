// AddRunnerSheet+Validation.swift
// RunnerBar

import Foundation

/// Computed validation helpers and state-check predicates for `AddRunnerSheet`.
extension AddRunnerSheet {

    // MARK: - Helpers (Add new)

    /// The resolved scope string.
    var effectiveScope: String { scopeType == .repo ? selectedRepo : selectedOrg }

    /// Returns `true` when the chosen install directory already contains a `.runner` file.
    var dirAlreadyConfigured: Bool {
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
        )
    }

    /// Guards the Register button.
    var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !effectiveScope.isEmpty
            && !dirAlreadyConfigured
    }

    // MARK: - Helpers (Add pre-existing)

    /// The GitHub URL to use for the import.
    var effectiveGitHubURL: String {
        detectedGitHubURL.isEmpty
            ? githubURLOverride.trimmingCharacters(in: .whitespaces)
            : detectedGitHubURL
    }

    /// Returns `true` when all pre-existing import preconditions are met.
    var canImport: Bool {
        !detectedName.isEmpty
            && existingError == nil
            && !isDuplicate
            && !effectiveGitHubURL.isEmpty
    }

    /// Returns `true` when the given runner name is already present in `runnerState.localRunners`.
    func checkDuplicate(runnerName: String) -> Bool {
        runnerState.localRunners.contains(where: { $0.runnerName == runnerName })
    }
}
