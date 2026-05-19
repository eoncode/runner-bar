import AppKit
import SwiftUI

// MARK: - RunnerDetailView
// Navigation level: SettingsView (runner row tap) → RunnerDetailView ← this view
//
// #491: Scaffold + read-only info block
// #492: Editable config fields (labels, workFolder, autoUpdate, proxy)
// #493: Danger Zone (remove only)

// MARK: - Save state helper
private enum SaveState: Equatable {
    case idle
    case saving
    case success
    case failure(String)
}

// MARK: - Danger action
private enum DangerAction: Identifiable, Equatable {
    case remove

    var id: String { "remove" }

    var title: String { "Remove runner" }

    var confirmLabel: String { "Remove" }

    var destructive: Bool { true }
}

// swiftlint:disable:next type_body_length
struct RunnerDetailView: View {
    let runner: RunnerModel
    let onBack: () -> Void

    @State private var isRunning: Bool
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    // MARK: - Editable field state (#492)
    @State private var labelsText: String
    @State private var labelsSaveState: SaveState = .idle
    @State private var workFolderText: String
    @State private var workFolderSaveState: SaveState = .idle
    /// `true` = auto-update enabled (written to .runner JSON as disableUpdate: false)
    @State private var autoUpdate: Bool
    @State private var autoUpdateSaveState: SaveState = .idle
    @State private var proxyUrl: String
    @State private var proxyUrlSaveState: SaveState = .idle
    @State private var proxyUser: String
    @State private var proxyPassword: String
    @State private var proxyCreditsSaveState: SaveState = .idle

    // MARK: - Danger Zone state (#493)
    @State private var dangerZoneExpanded = true
    @State private var pendingDangerAction: DangerAction?
    @State private var dangerActionState: SaveState = .idle

    init(runner: RunnerModel, onBack: @escaping () -> Void) {
        self.runner = runner
        self.onBack = onBack
        self._isRunning = State(initialValue: runner.isRunning)
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
        // Default to enabled; actual value loaded in onAppear
        self._autoUpdate = State(initialValue: true)
        self._proxyUrl = State(initialValue: "")
        self._proxyUser = State(initialValue: "")
        self._proxyPassword = State(initialValue: "")
    }

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
        .onChange(of: localRunnerStore.runners) { updated in
            if let fresh = updated.first(where: { $0.id == runner.id }) {
                isRunning = fresh.isRunning
            }
        }
        .sheet(item: $pendingDangerAction, content: dangerActionSheet)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.caption)
                    Text("Settings").font(.caption)
                }
                .foregroundColor(Color.rbTextSecondary)
                .fixedSize()
            }
            .buttonStyle(.plain)
            Spacer()
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(runner.runnerName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if isRunning {
                Button(action: stopRunner) { Text("Stop").font(.caption2) }
                    .buttonStyle(.bordered).help("Stop runner service")
            } else {
                Button(action: startRunner) { Text("Start").font(.caption2) }
                    .buttonStyle(.bordered).help("Start runner service")
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Runner Info")
            infoCard {
                if let url = runner.gitHubUrl {
                    infoRow(label: "GitHub URL", value: url, description: "The GitHub repository or organisation this runner is registered to.", copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                if let agentId = runner.agentId {
                    infoRow(label: "Agent ID", value: String(agentId), description: "Unique numeric ID assigned by GitHub when the runner was registered.")
                    Divider().padding(.leading, RBSpacing.md)
                }
                let osArch = [runner.platform, runner.platformArchitecture]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
                if !osArch.isEmpty {
                    infoRow(label: "OS / Arch", value: osArch, description: "Operating system and CPU architecture of this runner machine.")
                    Divider().padding(.leading, RBSpacing.md)
                }
                if let version = runner.agentVersion {
                    infoRow(label: "Version", value: version, description: "Installed GitHub Actions runner agent version.")
                    Divider().padding(.leading, RBSpacing.md)
                }
                if let installPath = runner.installPath {
                    infoRow(label: "Install path", value: installPath, description: "Folder on disk where the runner agent binaries are installed.", copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                infoRow(label: "Work folder", value: runner.workFolder ?? "_work", description: "Subfolder inside the install path used as the working directory for jobs.")
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No", description: "Ephemeral runners de-register automatically after completing a single job.")
                if !runner.labels.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Labels", value: runner.labels.joined(separator: ", "), description: "Tags used in workflow files to route jobs to this specific runner.")
                }
                if let group = runner.runnerGroup {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Runner group", value: group, description: "Organisation-level runner group this runner belongs to.")
                }
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Status", value: runner.displayStatus, description: "Current connectivity and availability state reported by GitHub.")
            }
        }
    }

    // MARK: - Config Section (#492)

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Configuration")
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Labels")
                                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                                .frame(width: 100, alignment: .leading).fixedSize()
                            Text("Custom comma-separated labels to route specific workflow jobs to this runner.")
                                .font(.caption2).foregroundColor(Color.rbTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField("comma-separated", text: $labelsText)
                            .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                        saveButton(state: labelsSaveState, action: saveLabels)
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    saveStateRow(labelsSaveState, restartNote: false)
                }
            }
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Work folder")
                                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                                .frame(width: 100, alignment: .leading).fixedSize()
                            Text("Directory used as the working directory during job execution. Requires runner restart.")
                                .font(.caption2).foregroundColor(Color.rbTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField("_work", text: $workFolderText)
                            .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                        saveButton(state: workFolderSaveState, action: saveWorkFolder)
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    saveStateRow(workFolderSaveState, restartNote: true)
                }
            }
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Autoupdate")
                                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                                .frame(width: 130, alignment: .leading).fixedSize()
                            Text("Allow the runner to automatically update itself when a new version is released.")
                                .font(.caption2).foregroundColor(Color.rbTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $autoUpdate)
                            .toggleStyle(.switch).labelsHidden()
                            .onChange(of: autoUpdate) { _ in saveAutoUpdate() }
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    saveStateRow(autoUpdateSaveState, restartNote: true)
                }
            }
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Proxy URL")
                                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                                .frame(width: 100, alignment: .leading).fixedSize()
                            Text("HTTP/HTTPS proxy the runner uses to reach GitHub. Leave blank for a direct connection.")
                                .font(.caption2).foregroundColor(Color.rbTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField("http://proxy:8080", text: $proxyUrl)
                            .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                        saveButton(state: proxyUrlSaveState, action: saveProxyUrl)
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    saveStateRow(proxyUrlSaveState, restartNote: true)
                }
            }
            infoCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Proxy user")
                                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                                .frame(width: 100, alignment: .leading).fixedSize()
                            Text("Username for authenticating with the proxy server.")
                                .font(.caption2).foregroundColor(Color.rbTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField("username", text: $proxyUser)
                            .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    Divider().padding(.leading, RBSpacing.md)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Proxy pass")
                                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                                .frame(width: 100, alignment: .leading).fixedSize()
                            Text("Password for authenticating with the proxy server.")
                                .font(.caption2).foregroundColor(Color.rbTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SecureField("password", text: $proxyPassword)
                            .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                        saveButton(state: proxyCreditsSaveState, action: saveProxyCredentials)
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    saveStateRow(proxyCreditsSaveState, restartNote: true)
                }
            }
        }
    }

    // MARK: - Danger Zone (#493)

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // swiftlint:disable:next multiple_closures_with_trailing_closure
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { dangerZoneExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbDanger)
                    Text("Danger Zone")
                        .font(RBFont.sectionHeader)
                        .foregroundColor(Color.rbDanger)
                    Spacer()
                    Image(systemName: dangerZoneExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Color.rbTextTertiary)
                }
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .buttonStyle(.plain)

            if dangerZoneExpanded {
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

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

    // MARK: - Danger Zone Trigger & Execute

    private func triggerDangerAction(_ action: DangerAction) {
        dangerActionState = .idle
        pendingDangerAction = action
    }

    private func executeDangerAction(_ action: DangerAction) {
        dangerActionState = .saving
        performRemove()
    }

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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 4)
    }

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

    private func infoRow(label: String, value: String, description: String? = nil, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                    .frame(width: 100, alignment: .leading).fixedSize()
                if let description = description {
                    Text(description)
                        .font(.caption2).foregroundColor(Color.rbTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

    private var dotColor: Color {
        switch runner.statusColor {
        case .running: return Color.rbSuccess
        case .busy:    return Color.rbWarning
        case .idle:    return Color.rbTextTertiary
        case .offline: return Color.rbDanger
        }
    }

    // MARK: - On Appear

    private func loadEditableFields() {
        guard let installPath = runner.installPath else { return }
        let runnerJSONPath = installPath + "/.runner"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: runnerJSONPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let disableUpdate = json["disableUpdate"] as? Bool ?? false
            autoUpdate = !disableUpdate
        }
        let proxyFilePath = installPath + "/.proxy"
        proxyUrl = (try? String(contentsOfFile: proxyFilePath, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let credPath = installPath + "/.proxycredentials"
        if let credContent = try? String(contentsOfFile: credPath, encoding: .utf8) {
            let lines = credContent.components(separatedBy: "\n")
            proxyUser = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            proxyPassword = lines.dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
    }

    // MARK: - Save Actions (#492)

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

    private func saveAutoUpdate() {
        guard let installPath = runner.installPath else {
            autoUpdateSaveState = .failure("Install path unknown"); return
        }
        autoUpdateSaveState = .saving
        // autoUpdate = true  → disableUpdate: false
        // autoUpdate = false → disableUpdate: true
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

    private func saveProxyUrl() {
        guard let installPath = runner.installPath else {
            proxyUrlSaveState = .failure("Install path unknown"); return
        }
        proxyUrlSaveState = .saving
        let value = proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            let filePath = installPath + "/.proxy"
            do {
                if value.isEmpty {
                    try? FileManager.default.removeItem(atPath: filePath)
                } else {
                    try value.write(toFile: filePath, atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.async {
                    proxyUrlSaveState = .success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if proxyUrlSaveState == .success { proxyUrlSaveState = .idle }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    proxyUrlSaveState = .failure("Failed to write .proxy: \(error.localizedDescription)")
                }
            }
        }
    }

    private func saveProxyCredentials() {
        guard let installPath = runner.installPath else {
            proxyCreditsSaveState = .failure("Install path unknown"); return
        }
        proxyCreditsSaveState = .saving
        let user = proxyUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            let filePath = installPath + "/.proxycredentials"
            do {
                if user.isEmpty && pass.isEmpty {
                    try? FileManager.default.removeItem(atPath: filePath)
                } else {
                    try "\(user)\n\(pass)".write(toFile: filePath, atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.async {
                    proxyCreditsSaveState = .success
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if proxyCreditsSaveState == .success { proxyCreditsSaveState = .idle }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    proxyCreditsSaveState = .failure("Failed to write .proxycredentials: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Start / Stop

    private func startRunner() {
        isRunning = true
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.start(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                default:
                    isRunning = false
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    private func stopRunner() {
        isRunning = false
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.stop(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                default:
                    isRunning = true
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }
}

// MARK: - .runner JSON patch helper

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
