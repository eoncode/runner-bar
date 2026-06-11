// RunnerEditDraft.swift
// RunnerBarCore
// Moved from RunnerBar app target to RunnerBarCore in Phase 5 (#1300)
// so that SaveRunnerEditsUseCase and tests can reference it without
// depending on the RunnerBar executable target.
import Foundation

// MARK: - RunnerEditDraft

/// A value-type buffer holding all editable fields for a runner.
/// Initialised from the live `RunnerModel` + local config files, then mutated in-memory
/// until the user confirms (OK) or discards (Cancel) in `RunnerDetailPopover`.
///
/// No persistence writes happen inside this type.
public struct RunnerEditDraft: Equatable, Sendable {

    // MARK: Labels
    /// User-visible label string (comma-separated), pre-filtered to remove system labels.
    public var labelsText: String

    // MARK: Runner JSON
    /// Work folder path written to `.runner` JSON as `workFolder`.
    public var workFolder: String
    /// When `true`, `disableUpdate` is written as `false` in `.runner` JSON.
    public var autoUpdate: Bool

    // MARK: Proxy
    /// Raw proxy URL written to `.proxy` file.
    public var proxyUrl: String
    /// Proxy username, first line of `.proxycredentials`.
    public var proxyUser: String
    /// Proxy password, second line of `.proxycredentials`.
    public var proxyPassword: String

    // MARK: - Init

    /// Seeds the draft from `runner` model values. Call `load(installPath:configStore:proxyStore:)` afterwards
    /// to override with on-disk values (auto-update, proxy) once the view appears.
    public init(runner: RunnerModel) {
        let systemLabels: Set<String> = ["self-hosted", "x64", "arm64", "linux", "macos", "windows"]
        self.labelsText = runner.labels
            .filter { !systemLabels.contains($0.lowercased()) }
            .joined(separator: ", ")
        self.workFolder = runner.workFolder ?? "_work"
        self.autoUpdate = true
        self.proxyUrl = ""
        self.proxyUser = ""
        self.proxyPassword = ""
    }

    // MARK: - Disk seeding

    /// Reads `.runner` JSON, `.proxy`, and `.proxycredentials` at `installPath`
    /// and overwrites the corresponding draft fields.
    ///
    /// Stores are injected so this method is usable in unit tests without
    /// hitting the real filesystem. Pass `RunnerConfigStore.shared` and
    /// `RunnerProxyStore.shared` at the call site in production.
    ///
    /// Returns the decoded `RunnerConfig` so callers can use its display-only
    /// fields (e.g. `platform`, `platformArchitecture`, `agentVersion`) without
    /// issuing a second disk read.
    @discardableResult
    public mutating func load(
        installPath: String,
        configStore: any RunnerConfigStoreProtocol,
        proxyStore: any RunnerProxyStoreProtocol
    ) async -> RunnerConfig? {
        let config = await loadRunnerConfig(installPath: installPath, store: configStore)
        let proxy  = await proxyStore.load(at: installPath)
        proxyUrl      = proxy.url
        proxyUser     = proxy.user
        proxyPassword = proxy.password
        return config
    }

    // MARK: - Parsed helpers

    /// Parsed, trimmed, non-empty label array derived from `labelsText`.
    public var parsedLabels: [String] {
        labelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Trimmed work folder string, falling back to `"_work"` when empty.
    public var trimmedWorkFolder: String {
        let v = workFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "_work" : v
    }

    // MARK: - Private disk helpers

    @discardableResult
    private mutating func loadRunnerConfig(
        installPath: String,
        store: any RunnerConfigStoreProtocol
    ) async -> RunnerConfig? {
        do {
            let config = try await store.load(at: installPath)
            autoUpdate = !(config.disableUpdate ?? false)
            if !config.workFolder.isEmpty {
                workFolder = config.workFolder
            }
            return config
        } catch {
            return nil
        }
    }
}
