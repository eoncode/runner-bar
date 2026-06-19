// SaveRunnerEditsUseCase.swift
// RunnerBarCore
// Phase 5 of the Swift 6.2 data model modernisation (#1287, #1300).
import Foundation

// MARK: - SaveRunnerEditsUseCase

/// Testable, dependency-injected replacement for the `commitRunnerEdit` free function.
///
/// Executes the three-step commit transaction:
/// 1. **Labels** (GitHub API) — aborts the entire commit on API failure.
///    If `agentId` or `gitHubUrl` are unavailable, the labels step cannot
///    run; an error is appended and execution **continues** to local writes
///    (steps 2 and 3). This is intentional: missing metadata is not the user's
///    fault and local config writes are still meaningful.
/// 2. **Runner JSON** — writes `workFolder` + `disableUpdate` via `configStore`.
/// 3. **Proxy files** — writes `.proxy` + `.proxycredentials` via `proxyStore`.
///
/// **Error semantics:**
/// - Labels API returns `nil` → immediate abort (steps 2 and 3 are skipped).
/// - Missing `agentId`/`gitHubUrl` → error appended, execution continues.
/// - JSON and proxy errors → accumulated independently; both steps always run
///   when applicable.
/// - `installPath == nil` while a JSON *or* proxy change is pending → immediate
///   abort with the accumulated errors so far. Without a known install path there
///   is no safe target for further writes. The `missingInstallPathForJSON` and
///   `missingInstallPathForProxy` tests document this behaviour explicitly.
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
        self.configStore = configStore
        self.proxyStore = proxyStore
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
            // Early return when installPath is nil: there is no safe target for
            // any further writes, so continuing would be a no-op. The proxy step
            // is also skipped — see the "Error semantics" section in the type doc.
            guard let installPath = runner.installPath else {
                errors.append("Install path unknown — cannot write runner JSON")
                return .failure(errors)
            }
            do {
                var config = try await configStore.load(at: installPath)
                config.workFolder = draft.trimmedWorkFolder
                // Assign nil (key omitted) when auto-update is enabled — the agent
                // treats key-absent and false identically, but omitting keeps the
                // file idiomatic. Only write true when the user explicitly disables.
                config.disableUpdate = draft.autoUpdate ? nil : true
                try await configStore.save(config, at: installPath)
            } catch {
                // Exhaustive switch — compiler enforces all RunnerConfigStoreError
                // cases are handled, matching the P22 intent of Step 3.
                switch error {
                case .readFailed(let path, let underlying):
                    errors.append("Cannot read config at \(path)/.runner: \(underlying.localizedDescription)")
                case .decodeFailed(let path):
                    errors.append("Cannot decode config at \(path)/.runner")
                case .writeFailed(let path, let underlying):
                    errors.append("Cannot write config at \(path)/.runner: \(underlying.localizedDescription)")
                }
            }
        }

        // MARK: Step 3 — Proxy files
        let proxyChanged = draft.proxyUrl != original.proxyUrl
            || draft.proxyUser != original.proxyUser
            || draft.proxyPassword != original.proxyPassword
        if proxyChanged {
            // Same early-return rationale as Step 2.
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
                switch error {
                case .writeFailed(let messages):
                    errors.append(contentsOf: messages)
                }
            }
        }

        return errors.isEmpty ? .success : .failure(errors)
    }

    // MARK: - Private helpers

    /// Extracts `owner/repo` or `orgName` scope from a GitHub HTML URL.
    /// Returns `nil` if the URL cannot be parsed.
    private func scopeFromHtmlUrl(_ url: String) -> String? {
        guard let parsedURL = URL(string: url) else { return nil }
        let parts = parsedURL.pathComponents.filter { $0 != "/" }
        if parts.count >= 2 { return parts[0] + "/" + parts[1] }
        if parts.count == 1 { return parts[0] }
        return nil
    }
}
