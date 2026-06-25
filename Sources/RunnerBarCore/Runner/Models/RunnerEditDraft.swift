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
/// Once the user confirms, the draft is passed to `SaveRunnerEditsUseCase.execute(...)`
/// where it crosses an actor isolation boundary. The parameter is annotated `consuming`
/// at that call site so the compiler (and future readers) understand that ownership
/// transfers into the async function and the caller should not read the draft afterwards.
///
/// No persistence writes happen inside this type.
///
/// - Note: Intended for single use. Pass to `SaveRunnerEditsUseCase.execute(runner:draft:original:)`
///   exactly once — the `consuming` annotation on that parameter makes reading the draft
///   variable afterwards a compile-time error. If a before/after diff is needed, copy the
///   draft before calling `execute`; inspect the copy afterwards.
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
        let proxy = await proxyStore.load(at: installPath)
        proxyUrl = proxy.url
        proxyUser = proxy.user
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
        let trimmed = workFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "_work" : trimmed
    }

    // MARK: - Private disk helpers

    /// Loads `.runner` JSON via `store`, applies `autoUpdate` and `workFolder` to the draft,
    /// and returns the decoded `RunnerConfig` for callers that need display-only fields.
    /// Logs and returns `nil` on any decoding or I/O error.
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
            log("RunnerEditDraft › loadRunnerConfig failed at \(installPath): \(error)")
            return nil
        }
    }
}
