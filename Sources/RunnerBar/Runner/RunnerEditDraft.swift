// RunnerEditDraft.swift
// RunnerBar
import Foundation
import RunnerBarCore

// MARK: - RunnerEditDraft

/// A value-type buffer holding all editable fields for a runner.
/// Initialised from the live `RunnerModel` + local config files, then mutated in-memory
/// until the user confirms (OK) or discards (Cancel) in `RunnerDetailPopover`.
///
/// No persistence writes happen inside this type.
struct RunnerEditDraft: Equatable, Sendable {

    // MARK: Labels
    /// User-visible label string (comma-separated), pre-filtered to remove system labels.
    var labelsText: String

    // MARK: Runner JSON
    /// Work folder path written to `.runner` JSON as `workFolder`.
    var workFolder: String
    /// When `true`, `disableUpdate` is written as `false` in `.runner` JSON.
    var autoUpdate: Bool

    // MARK: Proxy
    /// Raw proxy URL written to `.proxy` file.
    var proxyUrl: String
    /// Proxy username, first line of `.proxycredentials`.
    var proxyUser: String
    /// Proxy password, second line of `.proxycredentials`.
    var proxyPassword: String

    // MARK: - Init

    /// Seeds the draft from `runner` model values. Call `load(installPath:)` afterwards
    /// to override with on-disk values (auto-update, proxy) once the view appears.
    init(runner: RunnerModel) {
        // Filter out GitHub-managed system labels that are automatically assigned
        // by the runner registration process and should never be user-editable.
        // GitHub injects these as exact discrete tokens: self-hosted, x64, arm64,
        // linux, macos, windows. Exact Set membership is used (not substring matching)
        // so custom labels like "linux-ci" or "arm64-large" are preserved.
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
    /// Returns the decoded `RunnerConfig` so callers can use its display-only
    /// fields (e.g. `platform`, `platformArchitecture`, `agentVersion`) without
    /// issuing a second disk read.
    ///
    /// Designed to be called once from `onAppear` in the popover view.
    @discardableResult
    mutating func load(installPath: String) async -> RunnerConfig? {
        let config = await loadRunnerConfig(installPath: installPath)
        let proxy = await RunnerProxyStore.shared.load(at: installPath)
        proxyUrl      = proxy.url
        proxyUser     = proxy.user
        proxyPassword = proxy.password
        return config
    }

    // MARK: - Parsed helpers

    /// Parsed, trimmed, non-empty label array derived from `labelsText`.
    var parsedLabels: [String] {
        labelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Trimmed work folder string, falling back to `"_work"` when empty.
    var trimmedWorkFolder: String {
        let v = workFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "_work" : v
    }

    // MARK: - Private disk helpers

    /// Loads the `.runner` file via `RunnerConfigStore` and applies its values to the draft.
    /// Returns the decoded `RunnerConfig` so callers can consume display-only fields
    /// (e.g. `platform`, `platformArchitecture`, `agentVersion`) without a second disk read.
    @discardableResult
    private mutating func loadRunnerConfig(installPath: String) async -> RunnerConfig? {
        do {
            let config = try await RunnerConfigStore.shared.load(at: installPath)
            autoUpdate = !(config.disableUpdate ?? false)
            if !config.workFolder.isEmpty {
                workFolder = config.workFolder
            }
            return config
        } catch {
            log("RunnerEditDraft › loadRunnerConfig failed at \(installPath): \(error)")
            return nil
        }
    }
}
