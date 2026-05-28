// RunnerDetailView.swift
// RunnerBar
// swiftlint:disable missing_docs
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
// #973: Remove Danger Zone and Start/Stop from detail view — Settings is single source of truth

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

// swiftlint:disable:next type_body_length
/// Detail screen for a single self-hosted runner: displays info and editable config fields.
struct RunnerDetailView: View {
    /// The runner constant.
    let runner: RunnerModel
    /// The onBack constant.
    let onBack: () -> Void

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

    /// Creates a new instance.
    init(runner: RunnerModel, onBack: @escaping () -> Void) {
        self.runner = runner
        self.onBack = onBack
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

    /// Root settings detail layout containing the header, runner info, and editable configuration.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    infoSection
                    configSection
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .onAppear(perform: loadEditableFields)
    }

    // MARK: - Header (#532: two-row layout)

    /// Two-row header with a back button, runner name, and status dot.
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
                Circle().fill(dotColor(for: runner)).frame(width: 8, height: 8)
                Text(runner.runnerName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                infoRow(label: "Status", value: runner.displayStatus)
            }
        }
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
                        .onChange(of: autoUpdate) { _, _ in saveAutoUpdate() }
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

    // MARK: - Save button helper

    /// Returns a view representing the current save state: spinner, checkmark, error icon, or Save button.
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
    }

    /// Shows a restart note or failure message below a config card based on the current save state.
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
            .glassCard(cornerRadius: RBRadius.small)
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

    /// Status indicator color derived from the runner snapshot.
    private func dotColor(for runnerModel: RunnerModel) -> Color {
        runnerModel.isRunning ? Color.rbSuccess : Color.rbDanger
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
// swiftlint:enable missing_docs
