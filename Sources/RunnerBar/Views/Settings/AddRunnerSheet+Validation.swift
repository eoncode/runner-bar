// AddRunnerSheet+Validation.swift
// RunnerBar

import Foundation

// swiftlint:disable:next missing_docs
extension AddRunnerSheet {

    // MARK: - Helpers (Add new)

    /// The resolved scope string — the selected repo slug when repo-scoped,
    /// or the selected organisation name when org-scoped.
    var effectiveScope: String { scopeType == .repo ? selectedRepo : selectedOrg }

    /// Returns `true` when the chosen install directory already contains a `.runner` file,
    /// preventing accidental double-registration of the same path.
    var dirAlreadyConfigured: Bool {
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
        )
    }

    /// Guards the Register button: requires a non-empty runner name, a selected scope,
    /// and an install directory that has not already been configured.
    var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !effectiveScope.isEmpty
            && !dirAlreadyConfigured
    }

    // MARK: - Helpers (Add pre-existing)

    /// The GitHub URL to use for the import: detected from `.runner` or the manual override.
    var effectiveGitHubURL: String {
        detectedGitHubURL.isEmpty
            ? githubURLOverride.trimmingCharacters(in: .whitespaces)
            : detectedGitHubURL
    }

    /// Guards the Import button: requires a detected runner name, no parse error,
    /// no duplicate in the store, and a non-empty GitHub URL.
    var canImport: Bool {
        !detectedName.isEmpty
            && existingError == nil
            && !isDuplicate
            && !effectiveGitHubURL.isEmpty
    }

    /// Returns `true` when the given runner name is already tracked in `LocalRunnerStore`.
    func checkDuplicate(runnerName: String) -> Bool {
        LocalRunnerStore.shared.isTracked(runnerName: runnerName)
    }
}
