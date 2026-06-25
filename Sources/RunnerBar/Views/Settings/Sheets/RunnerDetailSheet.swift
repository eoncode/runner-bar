// RunnerDetailSheet.swift
// RunnerBar
import AppKit
import RunnerBarCore
import SwiftUI

// MARK: - RunnerDetailSheet

/// Sheet view for editing a single self-hosted runner.
///
/// All editable fields are buffered in a `RunnerEditDraft` value; no
/// persistence occurs here. The parent is responsible for committing
/// or discarding via the `onCommit` / `onCancel` callbacks.
///
/// Presented via `.sheet(item:)` from `LocalRunnersView` (#1262).
///
/// ## Why no ScrollView
/// The content is a fixed set of rows (Info + Config) that never needs to scroll.
/// A ScrollView prevents SwiftUI from computing a real `preferredContentSize` for
/// the sheet window — it reports the container height (i.e. the parent panel height)
/// instead of the content height. Removing the ScrollView lets the root VStack size
/// itself intrinsically, which gives the sheet the correct independent height.
/// ❌ NEVER wrap the content VStack in a ScrollView here.
///
/// ## Why no fixedSize on the content VStack
/// `.fixedSize(horizontal: false, vertical: true)` is intentionally absent from the
/// content VStack. The sheet window has no maximum-height constraint that could clip
/// the content — it simply grows to fit whatever height SwiftUI reports — so
/// `fixedSize` would add no protection. Worse, it would suppress flexible layout in
/// any `Text` children (including the `commitError` label in `footerBar`), breaking
/// word-wrap for long error strings. The `commitError` Text already carries its own
/// `.fixedSize(horizontal: false, vertical: true)` so it can grow vertically without
/// affecting sibling views.
///
/// Replaces `RunnerDetailView` as part of #1001 (issue #988 fix).
struct RunnerDetailSheet: View {

    // MARK: - Inputs

    /// The runner being edited (read-only identity + info fields).
    let runner: RunnerModel
    /// Error message from the last commit attempt, forwarded by the parent (`LocalRunnersView`).
    /// `nil` while no error is active. Displayed in the footer so the user knows why OK did not close.
    let commitError: String?
    /// Called when the user taps OK. The caller runs the commit flow (Phase 3).
    let onCommit: (RunnerEditDraft) -> Void
    /// Called when the user taps Cancel or the sheet is dismissed externally.
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

    /// Creates the sheet, seeding the draft and info fields from `runner`.
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

    /// Root sheet layout: header, form content, and action bar.
    ///
    /// No ScrollView (see type comment) and no fixedSize on the content VStack
    /// (see "Why no fixedSize" in type comment). The sheet window sizes freely
    /// to the intrinsic height of this VStack via `preferredContentSize`.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                infoSection
                configSection
            }
            .padding(.bottom, 16)
            Divider()
            footerBar
        }
        .frame(width: 440)
        .task { await loadDisplayFields() }
    }

    // MARK: - Header

    /// Sheet header showing runner status dot and name.
    private var sheetHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(runner.statusColor.color)
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

    /// Cancel / OK action bar at the bottom of the sheet.
    /// Shows `commitError` in red above the buttons when non-nil.
    /// The error Text carries `.fixedSize(horizontal: false, vertical: true)` so it
    /// word-wraps correctly without needing fixedSize on the parent VStack.
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
                    infoRow(label: "GitHub URL", value: url.absoluteString, copyable: true)
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
                    TextField("http://proxy:8080", text: $draft.proxyUrl) // NOSONAR — placeholder text, not a hardcoded URI call-site
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

    // MARK: - Sub-view helpers

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

    // MARK: - On Appear

    /// Seeds `displayOsArch` and `displayVersion` from the typed runner config,
    /// and loads disk values into the draft (auto-update, proxy).
    @MainActor
    private func loadDisplayFields() async {
        guard let installPath = runner.installPath else { return }

        var updatedDraft = draft
        // Pass stores explicitly — keeps singleton wiring in the app layer.
        // The parameterised overload is the testable Core API; the convenience
        // shim (load(installPath:)) is internal to Core and not visible here.
        let config = await updatedDraft.load(
            installPath: installPath,
            configStore: RunnerConfigStore.shared,
            proxyStore: RunnerProxyStore.shared
        )
        draft = updatedDraft
        originalDraft = draft

        guard let config else { return }

        if displayOsArch.isEmpty {
            let combined = [config.platform, config.platformArchitecture]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
            if !combined.isEmpty {
                displayOsArch = combined
            }
        }
        if displayVersion.isEmpty,
           let version = config.agentVersion,
           !version.isEmpty {
            displayVersion = version
        }
    }
}

/// Copies `text` to the system pasteboard.
/// File-local helper invoked by copy-to-clipboard buttons inside `RunnerDetailSheet`.
@MainActor
private func copyToPasteboard(text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
