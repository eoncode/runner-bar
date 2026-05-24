// RunnerDetailView.swift
// RunnerBar
// swiftlint:disable missing_docs
import AppKit
import Combine
import Foundation
import RunnerBarCore
import SwiftUI

// MARK: - Save state helper
/// Tracks the lifecycle of an async save operation for a single editable field.
private enum SaveState: Equatable {
    /// No save in progress.
    case idle
    /// Save request is in-flight.
    case saving
    /// Most recent save completed successfully.
    case success
    /// Most recent save failed; associated value is the error message.
    case failure(String)
}

// MARK: - Danger action
/// Represents a destructive action the user can trigger from the Danger Zone section.
private enum DangerAction: Identifiable, Equatable {
    /// De-register and delete the runner.
    case remove

    /// Stable identifier for `Identifiable` conformance.
    var id: String { "remove" }
    /// Human-readable action title shown in buttons and sheets.
    var title: String { "Remove runner" }
    /// Label used on the confirmation button inside the danger sheet.
    var confirmLabel: String { "Remove" }
    /// Whether the action is visually highlighted as destructive (red).
    var destructive: Bool { true }
}

// swiftlint:disable:next type_body_length
/// Detail screen for a single self-hosted runner: displays info, editable config fields, and the Danger Zone.
struct RunnerDetailView: View {
    /// The runner model displayed and edited by this view.
    let runner: RunnerModel
    /// Closure called when the user taps the back button.
    let onBack: () -> Void

    @State private var isRunning: Bool
    @State private var displayStatus: String
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    // MARK: - Editable field state (#492)
    @State private var labelsText: String
    @State private var labelsSaveState: SaveState = .idle
    @State private var workFolderText: String
    @State private var workFolderSaveState: SaveState = .idle
    @State private var autoUpdate: Bool
    @State private var autoUpdateSaveState: SaveState = .idle
    @State private var proxyUrl: String
    @State private var proxyUser: String
    @State private var proxyPassword: String
    @State private var proxySaveState: SaveState = .idle

    // MARK: - Info fields loaded from .runner JSON (#533)
    @State private var displayOsArch: String = ""
    @State private var displayVersion: String = ""

    // MARK: - Danger Zone state (#493)
    @State private var pendingDangerAction: DangerAction?
    @State private var dangerActionState: SaveState = .idle

    /// Creates a new `RunnerDetailView` for `runner`, calling `onBack` when the back button is tapped.
    init(runner: RunnerModel, onBack: @escaping () -> Void) {
        self.runner = runner
        self.onBack = onBack
        _isRunning = State(initialValue: runner.isRunning)
        _displayStatus = State(initialValue: runner.displayStatus)
        _labelsText = State(initialValue: runner.labels
            .filter { !["self-hosted"].contains($0)
                && !$0.lowercased().contains("x64")
                && !$0.lowercased().contains("arm64")
                && !$0.lowercased().contains("linux")
                && !$0.lowercased().contains("macos")
                && !$0.lowercased().contains("windows") }
            .joined(separator: ", ")
        )
        _workFolderText = State(initialValue: "")
        _autoUpdate = State(initialValue: true)
        self._proxyUrl = State(initialValue: "")
        self._proxyUser = State(initialValue: "")
        self._proxyPassword = State(initialValue: "")
        let osArch = [runner.platform, runner.platformArchitecture]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        self._displayOsArch = State(initialValue: osArch)
        self._displayVersion = State(initialValue: runner.agentVersion ?? "")
    }

    /// Root settings detail layout containing the header, runner info, editable configuration, and Danger Zone.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    configSection
                    dangerZoneSection
                }
            }
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear { loadEditableFields() }
        .onChange(of: localRunnerStore.runners) { updated in
            guard let fresh = updated.first(where: { $0.runnerName == runner.runnerName }) else { return }
            isRunning = fresh.isRunning
            displayStatus = fresh.displayStatus
        }
        .sheet(item: $pendingDangerAction, content: dangerActionSheet)
    }

    // MARK: - Header

    /// Navigation bar showing the back button, runner name, status dot, and Start/Stop toggle.
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Runners").font(.caption)
                }
                .foregroundColor(Color.rbTextSecondary)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(runner.runnerName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: isRunning ? stopRunner : startRunner) {
                    Text(isRunning ? "Stop" : "Start")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isRunning ? Color.rbDanger : Color.rbSuccess)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Info Section

    /// Card section listing static runner metadata: URL, work folder, ephemeral flag, OS/arch, version, and status.
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Runner Info")
            infoCard {
                if let url = runner.gitHubUrl {
                    infoRow(label: "GitHub URL", value: url, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                infoRow(label: "Work Folder", value: runner.workFolder ?? "—")
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No")
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "OS / Arch", value: displayOsArch.isEmpty ? "—" : displayOsArch)
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Version", value: displayVersion.isEmpty ? "—" : displayVersion)
                Divider().padding(.leading, RBSpacing.md)
                statusRow
            }
        }
    }

    /// Inline row showing the runner's current status string with a coloured dot.
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Status")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
            HStack(spacing: 4) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(displayStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.rbTextPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 7)
    }

    // MARK: - Config Section

    /// Card section with editable fields for labels, work folder, auto-update toggle, and proxy settings.
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Configuration")
            infoCard {
                configRow(
                    label: "Labels",
                    placeholder: "label1, label2",
                    text: $labelsText,
                    saveState: labelsSaveState,
                    onSave: saveLabels
                )
                saveStateRow(labelsSaveState, restartNote: false)
                Divider().padding(.leading, RBSpacing.md)
                configRow(
                    label: "Work Folder",
                    placeholder: "_work",
                    text: $workFolderText,
                    saveState: workFolderSaveState,
                    onSave: saveWorkFolder
                )
                saveStateRow(workFolderSaveState, restartNote: true)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Auto-Update")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading)
                    Toggle("", isOn: $autoUpdate)
                        .labelsHidden()
                        .onChange(of: autoUpdate) { _ in saveAutoUpdate() }
                    Spacer()
                    saveButton(state: autoUpdateSaveState) { saveAutoUpdate() }
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 8)
                Divider().padding(.leading, RBSpacing.md)
                Text("Proxy")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.rbTextTertiary)
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.top, 6)
                configRow(
                    label: "URL",
                    placeholder: "http://proxy:8080",
                    text: $proxyUrl,
                    saveState: proxySaveState,
                    onSave: {}
                )
                configRow(
                    label: "Username",
                    placeholder: "user",
                    text: $proxyUser,
                    saveState: proxySaveState,
                    onSave: {}
                )
                configRow(
                    label: "Password",
                    placeholder: "••••••",
                    text: $proxyPassword,
                    saveState: proxySaveState,
                    isSecure: true,
                    onSave: {}
                )
                HStack {
                    Spacer()
                    saveButton(state: proxySaveState) { saveProxy() }
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 6)
                saveStateRow(proxySaveState, restartNote: true)
            }
        }
    }

    /// Renders a label + text-field (or secure field) row with an optional inline Save button.
    private func configRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        saveState: SaveState,
        isSecure: Bool = false,
        onSave: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textFieldStyle(.plain)
            .onSubmit(onSave)
            Spacer()
            if label != "URL" && label != "Username" && label != "Password" {
                saveButton(state: saveState, action: onSave)
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Danger Zone

    /// Red-bordered card section with destructive runner actions (currently: Remove).
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color.rbDanger)
                Text("Danger Zone")
                    .font(RBFont.sectionHeader)
                    .foregroundColor(Color.rbDanger)
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 4)
            infoCard {
                dangerActionRow(
                    action: .remove,
                    description: "De-register this runner from GitHub and delete its install directory."
                )
                if case .failure(let msg) = dangerActionState {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(Color.rbDanger)
                        .padding(.horizontal, RBSpacing.md)
                        .padding(.bottom, 6)
                }
            }
        }
    }

    /// Renders a single danger-zone row with the action title, description, and trigger button.
    private func dangerActionRow(action: DangerAction, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.rbTextPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(Color.rbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Group {
                if dangerActionState == .saving {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action.title) { triggerDangerAction(action) }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(action.destructive ? Color.rbDanger : Color.rbTextSecondary)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    /// Confirmation sheet presented when the user triggers a danger-zone action.
    @ViewBuilder
    private func dangerActionSheet(_ action: DangerAction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title)
                .font(.headline)
            Text("This action cannot be undone. The runner will be de-registered from GitHub and its directory deleted.")
                .font(.body)
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .failure(let msg) = dangerActionState {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(Color.rbDanger)
            }
            HStack {
                Button("Cancel") { pendingDangerAction = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Group {
                    if dangerActionState == .saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action.confirmLabel) { executeDangerAction(action) }
                            .foregroundColor(action.destructive ? Color.rbDanger : nil)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    /// Sets `pendingDangerAction` to show the confirmation sheet for `action`.
    private func triggerDangerAction(_ action: DangerAction) {
        dangerActionState = .idle
        pendingDangerAction = action
    }

    /// Kicks off the concrete execution path for the confirmed danger action.
    private func executeDangerAction(_: DangerAction) {
        dangerActionState = .saving
        performRemove()
    }

    /// De-registers the runner via `RunnerLifecycleService`, then pops back on success.
    private func performRemove() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = RunnerLifecycleService.shared.remove(runner: runner)
            DispatchQueue.main.async {
                if ok {
                    LocalRunnerStore.shared.optimisticallyRemove(runner.runnerName)
                    pendingDangerAction = nil
                    onBack()
                } else {
                    dangerActionState = .failure("Remove failed — check logs")
                }
            }
        }
    }

    // MARK: - Save button helper

    /// Renders a Save button, spinner, checkmark, or error icon depending on `state`.
    @ViewBuilder
    private func saveButton(state: SaveState, action: @escaping () -> Void) -> some View {
        switch state {
        case .idle:
            Button("Save", action: action)
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(Color.rbTextSecondary)
        case .saving:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark").font(.caption).foregroundColor(Color.rbSuccess)
        case .failure:
            Image(systemName: "xmark").font(.caption).foregroundColor(Color.rbDanger)
        }
    }

    /// Renders a restart-required note or error message below a config row after a save attempt.
    @ViewBuilder
    private func saveStateRow(_ state: SaveState, restartNote: Bool) -> some View {
        if restartNote, state == .success {
            Text("Restart the runner service for changes to take effect.")
                .font(.caption)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md)
                .padding(.bottom, 4)
        } else if case .failure(let msg) = state {
            Text(msg)
                .font(.caption)
                .foregroundColor(Color.rbDanger)
                .padding(.horizontal, RBSpacing.md)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Sub-view helpers

    /// Returns a styled section-header `Text` view for use above each card.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    /// Wraps `content` in a rounded card with the standard surface + border styling.
    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                            .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
    }

    /// Renders a two-column label/value row; adds a copy-to-clipboard button when `copyable` is true.
    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.rbTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if copyable {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
    }

    /// Green when the runner is active, red when stopped.
    private var dotColor: Color {
        isRunning ? Color.rbSuccess : Color.rbDanger
    }

    // MARK: - On Appear

    // swiftlint:disable:next function_body_length
    private func loadEditableFields() {
        log("RunnerDetailView loadEditableFields ENTER runner=\(runner.runnerName) installPath=\(runner.installPath ?? "<nil>") platform=\(runner.platform ?? "<nil>") platformArch=\(runner.platformArchitecture ?? "<nil>") agentVersion=\(runner.agentVersion ?? "<nil>") displayOsArch=\(displayOsArch) displayVersion=\(displayVersion)")

        guard let installPath = runner.installPath else {
            log("RunnerDetailView loadEditableFields — no installPath, skipping JSON reads")
            return
        }

        let runnerFilePath = installPath + "/.runner"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: runnerFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("RunnerDetailView loadEditableFields — could not read/parse .runner JSON at \(runnerFilePath)")
            return
        }
        log("RunnerDetailView loadEditableFields — .runner JSON keys: \(json.keys.sorted())")

        if let workFolder = json["workFolder"] as? String {
            workFolderText = workFolder
            log("RunnerDetailView loadEditableFields workFolder=\(workFolder)")
        }
        if let disableUpdate = json["disableUpdate"] as? Bool {
            autoUpdate = !disableUpdate
            log("RunnerDetailView loadEditableFields disableUpdate=\(disableUpdate) → autoUpdate=\(autoUpdate)")
        }

        if displayOsArch.isEmpty {
            let platform = json["platform"] as? String ?? ""
            let arch     = json["platformArchitecture"] as? String ?? ""
            let combined = [platform, arch].filter { !$0.isEmpty }.joined(separator: " / ")
            if !combined.isEmpty {
                displayOsArch = combined
                log("RunnerDetailView loadEditableFields displayOsArch seeded from JSON=\(combined)")
            }
        } else {
            log("RunnerDetailView loadEditableFields displayOsArch already seeded from model=\(displayOsArch), skipping JSON override")
        }

        if displayVersion.isEmpty {
            let version = json["agentVersion"] as? String ?? ""
            if !version.isEmpty {
                displayVersion = version
                log("RunnerDetailView loadEditableFields displayVersion seeded from JSON=\(version)")
            }
        } else {
            log("RunnerDetailView loadEditableFields displayVersion already seeded from model=\(displayVersion), skipping JSON override")
        }

        let proxyFilePath = installPath + "/.proxy"
        let proxyContent = (try? String(contentsOfFile: proxyFilePath, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        proxyUrl = proxyContent

        let credFilePath = installPath + "/.proxycredentials"
        let credContent = (try? String(contentsOfFile: credFilePath, encoding: .utf8)) ?? ""
        let credLines = credContent.components(separatedBy: "\n")
        proxyUser     = credLines.first(where: { $0.hasPrefix("username=") }).map { String($0.dropFirst(9)) } ?? ""
        proxyPassword = credLines.first(where: { $0.hasPrefix("password=") }).map { String($0.dropFirst(9)) } ?? ""
        log("RunnerDetailView loadEditableFields proxy=\(proxyUrl) user=\(proxyUser) passwordIsEmpty=\(proxyPassword.isEmpty)")
    }

    // MARK: - Save Actions

    /// Persists custom labels to the GitHub API and patches the local `.runner` JSON.
    private func saveLabels() {
        guard let agentId = runner.agentId,
              let gitHubUrl = runner.gitHubUrl,
              let installPath = runner.installPath
        else { labelsSaveState = .failure("Runner metadata missing"); return }
        labelsSaveState = .saving
        let labels = labelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let scope = scopeFromHtmlUrl(gitHubUrl) else {
                DispatchQueue.main.async { labelsSaveState = .failure("Could not derive scope from URL") }
                return
            }
            let result = patchRunnerLabels(scope: scope, runnerID: agentId, labels: labels)
            if result != nil {
                patchRunnerJSON(installPath: installPath, key: "labels",
                                value: labels.map { ["type": "custom", "name": $0] as [String: Any] })
            }
            DispatchQueue.main.async {
                labelsSaveState = result != nil ? .success : .failure("API call failed")
            }
        }
    }

    /// Writes the new work-folder value to the `.runner` JSON on disk.
    private func saveWorkFolder() {
        guard let installPath = runner.installPath else {
            workFolderSaveState = .failure("Install path unknown"); return
        }
        workFolderSaveState = .saving
        let folder = workFolderText
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = patchRunnerJSON(installPath: installPath, key: "workFolder", value: folder)
            DispatchQueue.main.async {
                workFolderSaveState = ok ? .success : .failure("Failed to write .runner JSON")
            }
        }
    }

    /// Toggles `disableUpdate` in the `.runner` JSON to match the current `autoUpdate` binding.
    private func saveAutoUpdate() {
        guard let installPath = runner.installPath else {
            autoUpdateSaveState = .failure("Install path unknown"); return
        }
        autoUpdateSaveState = .saving
        let disable = !autoUpdate
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = patchRunnerJSON(installPath: installPath, key: "disableUpdate", value: disable)
            DispatchQueue.main.async {
                autoUpdateSaveState = ok ? .success : .failure("Failed to write .runner JSON")
            }
        }
    }

    /// Writes the proxy URL to `.proxy` and credentials to `.proxycredentials` on disk.
    private func saveProxy() {
        guard let installPath = runner.installPath else {
            proxySaveState = .failure("Install path unknown"); return
        }
        proxySaveState = .saving
        let url      = proxyUrl
        let user     = proxyUser
        let password = proxyPassword
        DispatchQueue.global(qos: .userInitiated).async {
            let proxyPath = installPath + "/.proxy"
            let credPath  = installPath + "/.proxycredentials"
            do {
                try url.write(toFile: proxyPath, atomically: true, encoding: .utf8)
                let cred = "username=\(user)\npassword=\(password)"
                try cred.write(toFile: credPath, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { proxySaveState = .success }
            } catch {
                DispatchQueue.main.async { proxySaveState = .failure(error.localizedDescription) }
            }
        }
    }

    // MARK: - Start / Stop

    /// Optimistically marks the runner running, then calls `RunnerLifecycleService.start`.
    private func startRunner() {
        isRunning = true
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.start(runner: runner)
            DispatchQueue.main.async {
                if case .success = result { } else {
                    isRunning = false
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                }
            }
        }
    }

    /// Optimistically marks the runner stopped, then calls `RunnerLifecycleService.stop`.
    private func stopRunner() {
        isRunning = false
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.stop(runner: runner)
            DispatchQueue.main.async {
                if case .success = result { } else {
                    isRunning = true
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
                }
            }
        }
    }
}

// MARK: - .runner JSON patch helper

/// Reads the `.runner` JSON at `installPath`, merges `key`/`value`, writes back, and returns success.
@discardableResult
private func patchRunnerJSON(
    installPath: String,
    key: String,
    value: Any
) -> Bool {
    let path = installPath + "/.runner"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { log("patchRunnerJSON › could not read/parse .runner at \(path)"); return false }
    json[key] = value
    guard let updated = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
    else { log("patchRunnerJSON › serialization failed for key=\(key)"); return false }
    do {
        try updated.write(to: URL(fileURLWithPath: path))
        log("patchRunnerJSON › wrote key=\(key) to \(path)")
        return true
    } catch {
        log("patchRunnerJSON › write failed: \(error)")
        return false
    }
}
// swiftlint:enable missing_docs
