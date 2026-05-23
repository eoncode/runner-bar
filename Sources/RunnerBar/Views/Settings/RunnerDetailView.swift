// RunnerDetailView.swift
// RunnerBar
import AppKit
import RunnerBarCore
import SwiftUI

// MARK: - RunnerDetailView
// Navigation level: SettingsView (runner row tap) → RunnerDetailView ← this view
//
// #491: Scaffold + read-only info block
// #492: Editable config fields (labels, workFolder, autoUpdate, proxy)
// #493: Danger Zone (remove only)
// #532: Redesign — two-row header, slim info section, unified proxy card
// #533: OS/Arch + Version rows in Runner Info; Danger Zone always expanded

// MARK: - Save state helper
/// Tracks the lifecycle of an async save operation for a single editable field.
private enum SaveState: Equatable {
    /// The `idle` case.
    case idle
    /// The `saving` case.
    case saving
    /// The `success` case.
    case success
    /// The `failure` case.
    case failure(String)
}

// MARK: - Danger action
/// Represents a destructive action the user can trigger from the Danger Zone section.
private enum DangerAction: Identifiable, Equatable {
    /// The `remove` case.
    case remove

    /// The id property.
    var id: String { "remove" }

    /// The title property.
    var title: String { "Remove runner" }

    /// The confirmLabel property.
    var confirmLabel: String { "Remove" }

    /// The destructive property.
    var destructive: Bool { true }
}

// swiftlint:disable:next type_body_length
/// Detail screen for a single self-hosted runner: displays info, editable config fields, and the Danger Zone.
struct RunnerDetailView: View {
    /// The runner constant.
    let runner: RunnerModel
    /// The onBack constant.
    let onBack: () -> Void

    /// The isRunning property.
    @State private var isRunning: Bool
    /// The displayStatus property.
    @State private var displayStatus: String
    /// The localRunnerStore property.
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    // MARK: - Editable field state (#492)
    /// The labelsText property.
    @State private var labelsText: String
    /// The labelsSaveState property.
    @State private var labelsSaveState: SaveState = .idle
    /// The workFolderText property.
    @State private var workFolderText: String
    /// The workFolderSaveState property.
    @State private var workFolderSaveState: SaveState = .idle
    /// `true` = auto-update enabled (written to .runner JSON as disableUpdate: false)
    @State private var autoUpdate: Bool
    /// The autoUpdateSaveState property.
    @State private var autoUpdateSaveState: SaveState = .idle
    // #532: unified proxy card — single save state for URL + user + pass
    /// The proxyUrl property.
    @State private var proxyUrl: String
    /// The proxyUser property.
    @State private var proxyUser: String
    /// The proxyPassword property.
    @State private var proxyPassword: String
    /// The proxySaveState property.
    @State private var proxySaveState: SaveState = .idle

    // MARK: - Info fields loaded from .runner JSON (#533)
    /// The displayOsArch property.
    @State private var displayOsArch: String = ""
    /// The displayVersion property.
    @State private var displayVersion: String = ""

    // MARK: - Danger Zone state (#493)
    /// The pendingDangerAction property.
    @State private var pendingDangerAction: DangerAction?
    /// The dangerActionState property.
    @State private var dangerActionState: SaveState = .idle

    /// Creates a new instance.
    init(runner: RunnerModel, onBack: @escaping () -> Void) {
        self.runner = runner
        self.onBack = onBack
        self._isRunning = State(initialValue: runner.isRunning)
        self._displayStatus = State(initialValue: runner.displayStatus)
        self._labelsText = State(initialValue: runner.labels
            .filter { !["self-hosted"].contains($0)
                && !$0.lowercased().contains("x64")
                && !$0.lowercased().contains("arm64")
                && !$0.lowercased().contains("linux")
                && !$0.lowercased().contains("macos")
                && !$0.lowercased().contains("windows") }
            .joined(separator: ", ")
        )
        self._workFolderText = State(initialValue: runner.workFolder ?? "_work")
        self._autoUpdate = State(initialValue: true)
        self._proxyUrl = State(initialValue: "")
        self._proxyUser = State(initialValue: "")
        self._proxyPassword = State(initialValue: "")
        // Seed OS/Arch + Version from model — onAppear will override from JSON if needed
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
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .onAppear(perform: loadEditableFields)
        .onChange(of: localRunnerStore.runners) { _ in
            if let fresh = localRunnerStore.runners.first(where: { $0.id == runner.id }) {
                isRunning = fresh.isRunning
                displayStatus = fresh.displayStatus
            }
        }
        .sheet(item: $pendingDangerAction, content: dangerActionSheet)
    }

    // MARK: - Header (#532: two-row layout)

    /// Two-row header with a back button, runner name, status dot, and start/stop control.
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Settings").font(.caption)
                }
                .foregroundColor(Color.rbTextSecondary)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(runner.runnerName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isRunning {
                    Button(action: stopRunner) { Text("Stop").font(.caption2) }
                        .buttonStyle(.bordered).help("Stop runner service")
                } else {
                    Button(action: startRunner) { Text("Start").font(.caption2) }
                        .buttonStyle(.bordered).help("Start runner service")
                }
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Info Section (#532 / #533)

    /// Read-only runner information card showing GitHub URL, work folder, ephemeral flag, OS/Arch, version, and status.
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
                statusRow
            }
        }
    }

    /// Status row used inside the info card, pairing the current `displayStatus` with a colored dot.
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Status")
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading).fixedSize()
            HStack(spacing: 4) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(displayStatus)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.rbTextPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 7)
    }

    // MARK: - Config Section (#532 / #533: single card with dividers)

    /// Editable configuration card for labels, work folder, auto-update, and proxy credentials.
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Configuration")
            infoCard {
                configRow(
                    label: "Labels",
                    placeholder: "comma-separated",
                    text: $labelsText,
                    saveState: labelsSaveState,
                    onSave: saveLabels
                )
                Divider().padding(.leading, RBSpacing.md)
                configRow(
                    label: "Work folder",
                    placeholder: "_work",
                    text: $workFolderText,
                    saveState: workFolderSaveState,
                    onSave: saveWorkFolder
                )
                Divider().padding(.leading, RBSpacing.md)
                HStack(spacing: 8) {
                    Text("Autoupdate")
                        .font(.system(size: 12))
                        .foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading)
                        .fixedSize()
                    Spacer()
                    Toggle("", isOn: $autoUpdate)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: autoUpdate) { _ in saveAutoUpdate() }
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 8)
                Divider().padding(.leading, RBSpacing.md)
                // #532: unified proxy — URL + user + pass + single Save
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
                    TextField("http://proxy:8080", text: $proxyUrl)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Username")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    TextField("username", text: $proxyUser)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Text("Password")
                        .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                        .frame(width: 100, alignment: .leading).fixedSize()
                    SecureField("password", text: $proxyPassword)
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                Divider().padding(.leading, RBSpacing.md)
                HStack {
                    Spacer()
                    saveButton(state: proxySaveState, action: saveProxy)
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.vertical, 6)
                saveStateRow(proxySaveState, restartNote: true)
            }
        }
    }

    /// Reusable editable config row with a label, text field or secure field, and trailing save button.
    private func configRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        saveState: SaveState,
        onSave: @escaping () -> Void,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            if secure {
                SecureField(placeholder, text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
            } else {
                TextField(placeholder, text: text)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
            }
            saveButton(state: saveState, action: onSave)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Danger Zone (#493 / #533: always expanded)

    /// Always-expanded destructive-actions section used for runner removal.
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(Color.rbDanger)
                Text("Danger Zone")
                    .font(RBFont.sectionHeader)
                    .foregroundColor(Color.rbDanger)
                Spacer()
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                dangerActionRow(
                    action: .remove,
                    description: "Permanently de-registers and removes this runner."
                )
            }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small)
                    .fill(Color.rbDanger.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: RBRadius.small)
                            .strokeBorder(Color.rbDanger.opacity(0.25), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
        }
    }

    /// Row inside the Danger Zone card showing the action title, description, and a trigger button.
    private func dangerActionRow(action: DangerAction, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(action.destructive ? Color.rbDanger : Color.rbTextPrimary)
                Text(description)
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // swiftlint:disable:next multiple_closures_with_trailing_closure
            Button(action: { triggerDangerAction(action) }) {
                Text(action.title)
                    .font(.caption2)
                    .foregroundColor(action.destructive ? Color.rbDanger : Color.rbTextPrimary)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Danger Zone Action Sheet

    /// Confirmation sheet presented before executing a destructive `DangerAction`.
    @ViewBuilder
    private func dangerActionSheet(_ action: DangerAction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title)
                .font(.headline)
                .padding(.top, 4)

            Text("This will de-register \"\(runner.runnerName)\" from GitHub and remove it from the list. The runner binary remains on disk.")
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)

            if case .failure(let msg) = dangerActionState {
                Text(msg).font(.caption2).foregroundColor(Color.rbDanger)
            }
            if dangerActionState == .success {
                Text("Done.").font(.caption2).foregroundColor(Color.rbSuccess)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    pendingDangerAction = nil
                    dangerActionState = .idle
                }
                .buttonStyle(.plain)
                .foregroundColor(Color.rbTextSecondary)
                Spacer()
                if dangerActionState == .saving {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button(action.confirmLabel) {
                        executeDangerAction(action)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rbDanger)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    /// Sets `pendingDangerAction` to show the confirmation sheet for the given action.
    private func triggerDangerAction(_ action: DangerAction) {
        dangerActionState = .idle
        pendingDangerAction = action
    }

    /// Dispatches to the appropriate handler based on the confirmed `DangerAction`.
    private func executeDangerAction(_ action: DangerAction) {
        dangerActionState = .saving
        performRemove()
    }

    /// De-registers the runner via the GitHub API and removes it from `LocalRunnerStore`.
    private func performRemove() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = RunnerLifecycleService.shared.remove(runner: runner)
            DispatchQueue.main.async {
                if ok {
                    dangerActionState = .success
                    LocalRunnerStore.shared.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        pendingDangerAction = nil
                        onBack()
                    }
                } else {
                    dangerActionState = .failure("Removal failed. Check logs.")
                }
            }
        }
    }

    // MARK: - Save button helper

    /// Performs the saveButton operation.
    @ViewBuilder
    private func saveButton(state: SaveState, action: @escaping () -> Void) -> some View {
        switch state {
        case .saving:
            ProgressView().scaleEffect(0.6).frame(width: 28, height: 20)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13)).foregroundColor(Color.rbSuccess).frame(width: 28)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13)).foregroundColor(Color.rbDanger).frame(width: 28)
        default:
            Button(action: action) { Text("Save").font(.caption2) }.buttonStyle(.bordered)
        }
    /// Performs the saveStateRow operation.
    }

    /// Performs the saveStateRow operation.
    @ViewBuilder
    private func saveStateRow(_ state: SaveState, restartNote: Bool) -> some View {
        if restartNote, state == .success {
            Text("Changes take effect after the next runner restart.")
                .font(.caption2).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
        } else if case .failure(let msg) = state {
            Text(msg).font(.caption2).foregroundColor(Color.rbDanger)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
        }
    }

    // MARK: - Sub-view helpers

    /// Styled section title label used above each settings card.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

    /// Rounded card container with a subtle border used to group related info or config rows.
    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.small)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
            )
            .padding(.horizontal, RBSpacing.md)
            .padding(.bottom, 8)
    }

    /// Label/value row inside an `infoCard`; when `copyable` is true a copy-to-clipboard button appears.
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
                // swiftlint:disable:next multiple_closures_with_trailing_closure
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Color.rbTextTertiary)
                }
                .buttonStyle(.plain).help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
    }

    // dotColor is derived from live isRunning state, not the frozen runner snapshot
    /// Status indicator color: green when running, red when offline, yellow otherwise.
    private var dotColor: Color {
        isRunning ? Color.rbSuccess : Color.rbDanger
    }

    // MARK: - On Appear

    // swiftlint:disable:next function_body_length
    /// Reads the runner's `.runner` JSON file and seeds `autoUpdate`, `proxyUrl`, `proxyUser`, `proxyPassword`, `displayOsArch`, and `displayVersion`.
    private func loadEditableFields() {
        log("RunnerDetailView loadEditableFields ENTER runner=\(runner.runnerName) installPath=\(runner.installPath ?? "<nil>") platform=\(runner.platform ?? "<nil>") platformArch=\(runner.platformArchitecture ?? "<nil>") agentVersion=\(runner.agentVersion ?? "<nil>") displayOsArch=\(displayOsArch) displayVersion=\(displayVersion)")

        guard let installPath = runner.installPath else {
            log("RunnerDetailView loadEditableFields BAIL installPath is nil for runner=\(runner.runnerName)")
            return
        }

        let runnerJSONPath = installPath + "/.runner"
        log("RunnerDetailView loadEditableFields reading JSON path=\(runnerJSONPath)")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: runnerJSONPath)) else {
            log("RunnerDetailView loadEditableFields ERROR could not read .runner file at \(runnerJSONPath)")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("RunnerDetailView loadEditableFields ERROR could not parse JSON at \(runnerJSONPath) dataBytes=\(data.count)")
            return
        }

        log("RunnerDetailView loadEditableFields JSON keys=\(json.keys.sorted().joined(separator: ","))")

        let disableUpdate = json["disableUpdate"] as? Bool ?? false
        autoUpdate = !disableUpdate
        log("RunnerDetailView loadEditableFields disableUpdate=\(disableUpdate) → autoUpdate=\(autoUpdate)")

        if displayOsArch.isEmpty {
            let platform = json["platform"] as? String ?? ""
            let arch = json["platformArchitecture"] as? String ?? ""
            log("RunnerDetailView loadEditableFields platform=\(platform) arch=\(arch) (from JSON)")
            let combined = [platform, arch].filter { !$0.isEmpty }.joined(separator: " / ")
            if !combined.isEmpty {
                displayOsArch = combined
                log("RunnerDetailView loadEditableFields set displayOsArch=\(combined)")
            } else {
                log("RunnerDetailView loadEditableFields WARNING platform+arch both empty in JSON, displayOsArch stays empty")
            }
        } else {
            log("RunnerDetailView loadEditableFields displayOsArch already seeded from model=\(displayOsArch), skipping JSON override")
        }

        if displayVersion.isEmpty {
            if let version = json["agentVersion"] as? String, !version.isEmpty {
                displayVersion = version
                log("RunnerDetailView loadEditableFields set displayVersion=\(version)")
            } else {
                log("RunnerDetailView loadEditableFields WARNING agentVersion missing or empty in JSON keys=\(json.keys.sorted())")
            }
        } else {
            log("RunnerDetailView loadEditableFields displayVersion already seeded from model=\(displayVersion), skipping JSON override")
        }

        // Proxy
        let proxyFilePath = installPath + "/.proxy"
        let proxyContent = (try? String(contentsOfFile: proxyFilePath, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        proxyUrl = proxyContent
        log("RunnerDetailView loadEditableFields proxyUrl=\(proxyUrl.isEmpty ? "<empty>" : proxyUrl)")

        let credPath = installPath + "/.proxycredentials"
        if let credContent = try? String(contentsOfFile: credPath, encoding: .utf8) {
            let lines = credContent.components(separatedBy: "\n")
            proxyUser = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            proxyPassword = lines.dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            log("RunnerDetailView loadEditableFields proxyUser=\(proxyUser.isEmpty ? "<empty>" : "<set>") proxyPassword=\(proxyPassword.isEmpty ? "<empty>" : "<set>")")
        } else {
            log("RunnerDetailView loadEditableFields no .proxycredentials file at \(credPath)")
        }

        log("RunnerDetailView loadEditableFields EXIT displayOsArch=\(displayOsArch) displayVersion=\(displayVersion)")
    }

    // MARK: - Save Actions

    /// Patches the runner's labels via `patchRunnerJSON` and updates `labelsSaveState`.
    private func saveLabels() {
        guard let agentId = runner.agentId,
              let gitHubUrl = runner.gitHubUrl,
              let scope = scopeFromHtmlUrl(gitHubUrl)
        else {
            labelsSaveState = .failure("No agent ID or GitHub URL — cannot save via API")
            return
        }
        let parsed = labelsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        labelsSaveState = .saving
        DispatchQueue.global(qos: .userInitiated).async {
            let result = patchRunnerLabels(scope: scope, runnerID: agentId, labels: parsed)
            DispatchQueue.main.async {
                if result != nil {
                    labelsSaveState = .success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if labelsSaveState == .success { labelsSaveState = .idle }
                    }
                } else {
                    labelsSaveState = .failure("Failed to save labels via GitHub API")
                }
            }
        }
    }

    /// Patches the runner's work folder path via `patchRunnerJSON` and updates `workFolderSaveState`.
    private func saveWorkFolder() {
        guard let installPath = runner.installPath else {
            workFolderSaveState = .failure("Install path unknown"); return
        }
        workFolderSaveState = .saving
        let value = workFolderText.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = patchRunnerJSON(installPath: installPath, key: "workFolder", stringValue: value)
            DispatchQueue.main.async {
                workFolderSaveState = ok ? .success : .failure("Failed to write .runner JSON")
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if workFolderSaveState == .success { workFolderSaveState = .idle }
                    }
                }
            }
        }
    }

    /// Writes the `disableUpdate` flag to the runner JSON and updates `autoUpdateSaveState`.
    private func saveAutoUpdate() {
        guard let installPath = runner.installPath else {
            autoUpdateSaveState = .failure("Install path unknown"); return
        }
        autoUpdateSaveState = .saving
        let disableUpdate = !autoUpdate
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = patchRunnerJSON(installPath: installPath, key: "disableUpdate", boolValue: disableUpdate)
            DispatchQueue.main.async {
                autoUpdateSaveState = ok ? .success : .failure("Failed to write .runner JSON")
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if autoUpdateSaveState == .success { autoUpdateSaveState = .idle }
                    }
                }
            }
        }
    }

    // #532: unified proxy save — writes .proxy + .proxycredentials in one action
    /// Persists proxy URL, username, and password to the runner JSON and updates `proxySaveState`.
    private func saveProxy() {
        guard let installPath = runner.installPath else {
            proxySaveState = .failure("Install path unknown"); return
        }
        proxySaveState = .saving
        let urlValue = proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = proxyUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            let proxyFilePath = installPath + "/.proxy"
            do {
                if urlValue.isEmpty {
                    if FileManager.default.fileExists(atPath: proxyFilePath) {
                        try FileManager.default.removeItem(atPath: proxyFilePath)
                    }
                } else {
                    try urlValue.write(toFile: proxyFilePath, atomically: true, encoding: .utf8)
                }
            } catch { ok = false }
            let credPath = installPath + "/.proxycredentials"
            do {
                if user.isEmpty && pass.isEmpty {
                    if FileManager.default.fileExists(atPath: credPath) {
                        try FileManager.default.removeItem(atPath: credPath)
                    }
                } else {
                    try "\(user)\n\(pass)".write(toFile: credPath, atomically: true, encoding: .utf8)
                }
            } catch { ok = false }
            DispatchQueue.main.async {
                proxySaveState = ok ? .success : .failure("Failed to save proxy settings")
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if proxySaveState == .success { proxySaveState = .idle }
                    }
                }
            }
        }
    }

    // MARK: - Start / Stop

    /// Launches the runner service via `LocalRunnerStore` and sets `isRunning` to true.
    private func startRunner() {
        isRunning = true
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.start(runner: runner)
            DispatchQueue.main.async {
                if case .success = result {
                    // success — no additional action needed
                } else {
                    isRunning = false
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    /// Stops the runner service via `LocalRunnerStore` and sets `isRunning` to false.
    private func stopRunner() {
        isRunning = false
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.stop(runner: runner)
            DispatchQueue.main.async {
                if case .success = result {
                    // success — no additional action needed
                } else {
                    isRunning = true
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }
}

// MARK: - .runner JSON patch helper

/// Reads the `.runner` JSON at `path`, merges `patch` keys, and writes the result back to disk.
private func patchRunnerJSON(
    installPath: String,
    key: String,
    stringValue: String? = nil,
    boolValue: Bool? = nil
) -> Bool {
    let path = installPath + "/.runner"
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        log("patchRunnerJSON › failed to read \(path)")
        return false
    }
    if let sv = stringValue { json[key] = sv }
    if let bv = boolValue   { json[key] = bv }
    guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
        log("patchRunnerJSON › serialization failed for key=\(key)")
        return false
    }
    do {
        try newData.write(to: url, options: .atomic)
        log("patchRunnerJSON › wrote key=\(key) to \(path)")
        return true
    } catch {
        log("patchRunnerJSON › write failed: \(error)")
        return false
    }
}
