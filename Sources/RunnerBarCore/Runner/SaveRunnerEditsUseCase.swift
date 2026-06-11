// SaveRunnerEditsUseCase.swift
// RunnerBarCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation

// MARK: - SaveRunnerEditsUseCase

/// Testable, dependency-injected replacement for the `commitRunnerEdit` free function.
///
/// Executes the three-step commit transaction:
/// 1. **Labels** (GitHub API) — aborts the entire commit on API failure.
///    If `agentId` or `gitHubUrl` are unavailable, appends an error and
///    continues to local writes.
/// 2. **Runner JSON** — writes `workFolder` + `disableUpdate` via `configStore`.
/// 3. **Proxy files** — writes `.proxy` + `.proxycredentials` via `proxyStore`.
///
/// JSON and proxy errors are accumulated; labels abort early.
///
/// All dependencies are injected — no singletons are accessed inside `execute(...)`.
/// Use `RunnerConfigStore.shared`, `RunnerProxyStore.shared`, and
/// `DefaultRunnerLabelsService()` for production.
///
/// - Note: Part of Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
public struct SaveRunnerEditsUseCase: Sendable {

    // MARK: Dependencies

    /// Store for reading and writing the `.runner` JSON config file.
    public let configStore: any RunnerConfigStoreProtocol
    /// Store for reading and writing `.proxy` / `.proxycredentials` files.
    public let proxyStore: any RunnerProxyStoreProtocol
    /// Service for updating runner labels via the GitHub API.
    public let labelsService: any RunnerLabelsService

    // MARK: - Init

    /// Creates a `SaveRunnerEditsUseCase` with the given dependency implementations.
    /// Pass `RunnerConfigStore.shared`, `RunnerProxyStore.shared`, and
    /// `DefaultRunnerLabelsService()` for production use.
    public init(
        configStore: any RunnerConfigStoreProtocol,
        proxyStore: any RunnerProxyStoreProtocol,
        labelsService: any RunnerLabelsService
    ) {
        self.configStore   = configStore
        self.proxyStore    = proxyStore
        self.labelsService = labelsService
    }

    // MARK: - execute

    /// Persists all changed fields in `draft` for `runner` as a single transaction.
    ///
    /// - Returns: `.success` when all writes succeed;
    ///   `.failure([String])` with human-readable messages otherwise.
    public func execute(
        runner: RunnerModel,
        draft: RunnerEditDraft,
        original: RunnerEditDraft
    ) async -> CommitResult {
        var errors: [String] = []

        // MARK: Step 1 — Labels (GitHub API)
        let labelsChanged = draft.parsedLabels != original.parsedLabels
        if labelsChanged {
            if let agentId = runner.agentId,
               let gitHubUrl = runner.gitHubUrl,
               let scope = scopeFromHtmlUrl(gitHubUrl) {
                let result = await labelsService.patch(scope: scope, runnerID: agentId, labels: draft.parsedLabels)
                if result == nil {
                    return .failure(["Failed to save labels via GitHub API"])
                }
            } else {
                errors.append("Cannot save labels: missing agent ID or GitHub URL")
            }
        }

        // MARK: Step 2 — Runner JSON (workFolder + disableUpdate)
        let workFolderChanged = draft.trimmedWorkFolder != original.trimmedWorkFolder
        let autoUpdateChanged = draft.autoUpdate != original.autoUpdate
        if workFolderChanged || autoUpdateChanged {
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write runner JSON")
                return .failure(errors)
            }
            do {
                var config = try await configStore.load(at: installPath)
                config.workFolder = draft.trimmedWorkFolder
                config.disableUpdate = !draft.autoUpdate
                try await configStore.save(config, at: installPath)
            } catch {
                errors.append("Failed to write runner configuration (.runner JSON)")
            }
        }

        // MARK: Step 3 — Proxy files
        let proxyChanged = draft.proxyUrl != original.proxyUrl
            || draft.proxyUser != original.proxyUser
            || draft.proxyPassword != original.proxyPassword
        if proxyChanged {
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write proxy files")
                return .failure(errors)
            }
            let proxyConfig = RunnerProxyConfig(
                url: draft.proxyUrl,
                user: draft.proxyUser,
                password: draft.proxyPassword
            )
            do {
                try await proxyStore.save(proxyConfig, at: installPath)
            } catch {
                errors.append("Failed to save proxy settings")
            }
        }

        return errors.isEmpty ? .success : .failure(errors)
    }

    // MARK: - Private helpers

    /// Extracts `owner/repo` or `orgName` scope from a GitHub HTML URL.
    /// Returns `nil` if the URL cannot be parsed.
    private func scopeFromHtmlUrl(_ url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        let parts = u.pathComponents.filter { $0 != "/" }
        if parts.count >= 2 { return parts[0] + "/" + parts[1] }
        if parts.count == 1 { return parts[0] }
        return nil
    }
}
