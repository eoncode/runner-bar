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
    /// Designed to be called once from `onAppear` in the popover view.
    mutating func load(installPath: String) {
        loadRunnerJSON(installPath: installPath)
        loadProxy(installPath: installPath)
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

    /// Reads and parses the `.runner` JSON at `installPath`, applies `autoUpdate` and
    /// `workFolder` to the draft, and returns the raw dictionary for callers that need
    /// additional fields (e.g. `platform`, `agentVersion`) without a second file read.
    /// The return value may be discarded if only the draft side-effects are needed.
    @discardableResult
    mutating func loadRunnerJSON(installPath: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: installPath).appendingPathComponent(".runner")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let disableUpdate = json["disableUpdate"] as? Bool ?? false
        autoUpdate = !disableUpdate
        if let wf = json["workFolder"] as? String, !wf.isEmpty {
            workFolder = wf
        }
        return json
    }

    /// Reads `.proxy` and `.proxycredentials` at `installPath` and applies values to the draft.
    /// `.proxy` — single line containing the raw proxy URL.
    /// `.proxycredentials` — two-line format: line 1 = username, line 2 = password.
    /// Missing files leave the corresponding draft fields as empty strings.
    private mutating func loadProxy(installPath: String) {
        let base = URL(fileURLWithPath: installPath)
        let proxyURL = base.appendingPathComponent(".proxy")
        let credURL = base.appendingPathComponent(".proxycredentials")

        proxyUrl = (try? String(contentsOf: proxyURL, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        if let credContent = try? String(contentsOf: credURL, encoding: .utf8) {
            let lines = credContent.components(separatedBy: "\n")
            proxyUser = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            proxyPassword = lines.indices.contains(1)
                ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
        }
    }
}
