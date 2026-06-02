// RunnerDetailPopover.swift
// RunnerBar
import AppKit
import RunnerBarCore
import SwiftUI

// MARK: - RunnerDetailPopover

/// Popover view for editing a single self-hosted runner.
///
/// All editable fields are buffered in a `RunnerEditDraft` value; no
/// persistence occurs here.  The parent is responsible for committing
/// or discarding via the `onCommit` / `onCancel` callbacks.
///
/// Replaces `RunnerDetailView` as part of #1001 (issue #988 fix).
struct RunnerDetailPopover: View {

    // MARK: - Inputs

    /// The runner being edited (read-only identity + info fields).
    let runner: RunnerModel
    /// Error message from the last commit attempt, forwarded by the parent (`SettingsView`).
    /// `nil` while no error is active. Displayed in the footer so the user knows why OK did not close.
    let commitError: String?
    /// Called when the user taps OK. The caller runs the commit flow (Phase 3).
    let onCommit: (RunnerEditDraft) -> Void
    /// Called when the user taps Cancel or the popover is dismissed externally.
    let onCancel: () -> Void

    // MARK: - Draft state

    /// Mutable draft buffering all editable values until OK is tapped.
    @State private var draft: RunnerEditDraft
    // Intentionally set twice: seeded in init() from the model, then overwritten in
    // loadDisplayFields() after disk values are loaded so the dirty-check baseline
    // reflects actual persisted state rather than the model-only snapshot.
    /// Snapshot of the draft at load time; used to detect unsaved changes.
    @State private var originalDraft: RunnerEditDraft

    // MARK: - Info fields (read-only, loaded from .runner JSON)

    /// OS and architecture string loaded from the runner's JSON file.
    @State private var displayOsArch: String
    /// Agent version string loaded from the runner's JSON file.
    @State private var displayVersion: String

    // MARK: - Init

    /// Creates the popover, seeding the draft and info fields from `runner`.
    init(
        runner: RunnerModel,
        commitError: String? = nil,
        onCommit: @escaping (RunnerEditDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.runner = runner
        self.commitError = commitError
        self.onCommit = onCommit
        self.onCancel = onCancel

        let initial = RunnerEditDraft(runner: runner)
        self._draft = State(initialValue: initial)
        self._originalDraft = State(initialValue: initial)

        let osArch = [runner.platform, runner.platformArchitecture]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        self._displayOsArch = State(initialValue: osArch)
        self._displayVersion = State(initialValue: runner.agentVersion ?? "")
    }

    // MARK: - Body

    /// Root popover layout: header, form fields, and action bar.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverHeader
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    configSection
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footerBar
        }
        .frame(width: 440)
        .onAppear(perform: loadDisplayFields)
    }

    // MARK: - Header

    /// Popover header showing runner status dot and name (no back button).
    private var popoverHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor(for: runner))
                .frame(width: 8, height: 8)
            Text(runner.runnerName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Footer

    /// Cancel / OK action bar at the bottom of the popover.
    /// Shows `commitError` in red above the buttons when non-nil so the user
    /// knows why OK did not close the popover.
    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = commitError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(Color.rbDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("OK") { onCommit(draft) }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 10)
            .padding(.top, commitError == nil ? 10 : 4)
        }
    }

    // MARK: - Info Section

    /// Read-only runner information card: GitHub URL, work folder, ephemeral flag, OS/Arch, version, status.
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Runner Info")
            infoCard {
                if let url = runner.gitHubUrl {
                    infoRow(label: "GitHub URL", value: url, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                infoRow(label: "Work folder", value: runner.workFolder ?? "_work")
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No")
                if !displayOsArch.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "OS / Arch", value: displayOsArch)
                }
                if !displayVersion.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Version", value: displayVersion)
                }
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Status", value: runner.displayStatus)
            }
        }
    }

    // MARK: - Config Section

    /// Editable configuration card bound to `draft`. No inline save buttons.
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Configuration")
            infoCard {
                // Labels
                configRow(label: "Labels", placeholder: "comma-separated", text: $draft.labelsText)
                Divider().padding(.leading, RBSpacing.md)
                // Work folder
                configRow(label: "Work folder", placeholder: "_work", text: $draft.workFolder)
                Divider().padding(.leading, RBSpacing.md)
                // Auto-update toggle — mutation stays in draft; no onChange persistence
                HStack(spacing: 8) {
                    Text("Autoupdate")
                        .font(.system(size: 12))
                        .foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading)
                        .fixedSize()
                    Spacer()
                    Toggle("", isOn: $draft.autoUpdate)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 8)
                Divider().padding(.leading, RBSpacing.md)
                // Proxy sub-section
                Text("Proxy")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.rbTextTertiary)
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("URL")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    TextField("http://proxy:8080", text: $draft.proxyUrl)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Username")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    TextField("username", text: $draft.proxyUser)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Password")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    SecureField("password", text: $draft.proxyPassword)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
            }
        }
    }

    // MARK: - Config row helper

    /// Label + text field row inside a config card. No save button or save state.
    private func configRow(
        label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            TextField(placeholder, text: text)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Sub-view helpers (mirrored from RunnerDetailView)

    /// Styled section title used above each settings card.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    /// Rounded card container grouping related rows.
    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .glassCard(cornerRadius: RBRadius.small)
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
    }

    /// Label/value read-only row with optional copy-to-clipboard button.
    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading).fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(Color.rbTextPrimary)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    copyToPasteboard(text: value)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain).help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
    }

    /// Status indicator colour from runner model.
    /// Matches the 4-state logic in `SettingsView.localRunnerDotColor(for:)`.
    private func dotColor(for runnerModel: RunnerModel) -> Color {
        switch runnerModel.statusColor {
        case .running: return Color.rbSuccess
        case .busy:    return Color.rbWarning
        case .idle:    return Color.rbTextTertiary
        case .offline: return Color.rbDanger
        }
    }

    // MARK: - On Appear

    /// Seeds `displayOsArch` and `displayVersion` from the `.runner` JSON,
    /// and loads disk values into the draft (auto-update, proxy).
    /// TODO: #1077 — `draft.load(installPath:)` reads `.runner` JSON synchronously on
    /// `@MainActor`. Migrate to async once the load path is async-capable.
    private func loadDisplayFields() {
        guard let installPath = runner.installPath else { return }

        // Load disk values into draft
        draft.load(installPath: installPath)
        // Snapshot original after disk load so dirty-check is accurate
        originalDraft = draft

        // Override info fields from JSON if model values were empty
        let runnerJSONPath = installPath + "/.runner"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: runnerJSONPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if displayOsArch.isEmpty {
            let combined = [json["platform"] as? String, json["platformArchitecture"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
            if !combined.isEmpty { displayOsArch = combined }
        }
        if displayVersion.isEmpty, let v = json["agentVersion"] as? String, !v.isEmpty {
            displayVersion = v
        }
    }
}

/// Copies `text` to the system pasteboard. File-local helper used by copy buttons.
@MainActor
private func copyToPasteboard(text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
