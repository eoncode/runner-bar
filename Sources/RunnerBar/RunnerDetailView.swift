import AppKit
import SwiftUI

// MARK: - RunnerDetailView
// Navigation level: SettingsView (runner row tap) → RunnerDetailView ← this view
//
// #491: Scaffold + read-only info block
// #492: Editable config fields (labels, workFolder, disableUpdate, proxy)
// #493: Danger Zone (rename, move, ephemeral toggle, runner group, remove)

// MARK: - Save state helper
private enum SaveState: Equatable {
    case idle
    case saving
    case success
    case failure(String)
}

// MARK: - Danger action
private enum DangerAction: Identifiable, Equatable {
    case rename
    case move
    case toggleEphemeral
    case changeGroup
    case remove

    var id: String {
        switch self {
        case .rename:          return "rename"
        case .move:            return "move"
        case .toggleEphemeral: return "toggleEphemeral"
        case .changeGroup:     return "changeGroup"
        case .remove:          return "remove"
        }
    }

    var title: String {
        switch self {
        case .rename:          return "Rename runner"
        case .move:            return "Move to different repo / org"
        case .toggleEphemeral: return "Toggle ephemeral mode"
        case .changeGroup:     return "Change runner group"
        case .remove:          return "Remove runner"
        }
    }

    var confirmLabel: String {
        switch self {
        case .rename:          return "Rename & re-register"
        case .move:            return "Move & re-register"
        case .toggleEphemeral: return "Toggle & re-register"
        case .changeGroup:     return "Change & re-register"
        case .remove:          return "Remove"
        }
    }

    var destructive: Bool { self == .remove }
    /// Actions that require a full de-register + re-register cycle.
    var requiresReregistration: Bool { self != .remove }
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
    @State private var disableUpdate: Bool
    @State private var disableUpdateSaveState: SaveState = .idle
    @State private var proxyUrl: String
    @State private var proxyUrlSaveState: SaveState = .idle
    @State private var proxyUser: String
    @State private var proxyPassword: String
    @State private var proxyCreditsSaveState: SaveState = .idle

    // MARK: - Danger Zone state (#493)
    @State private var dangerZoneExpanded = false
    @State private var pendingDangerAction: DangerAction?
    /// Single text input used by rename / move / changeGroup sheets.
    @State private var dangerInputA = ""
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
        self._disableUpdate = State(initialValue: false)
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
                    infoRow(label: "GitHub URL", value: url, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                if let agentId = runner.agentId {
                    infoRow(label: "Agent ID", value: String(agentId))
                    Divider().padding(.leading, RBSpacing.md)
                }
                let osArch = [runner.platform, runner.platformArchitecture]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
                if !osArch.isEmpty {
                    infoRow(label: "OS / Arch", value: osArch)
                    Divider().padding(.leading, RBSpacing.md)
                }
                if let version = runner.agentVersion {
                    infoRow(label: "Version", value: version)
                    Divider().padding(.leading, RBSpacing.md)
                }
                if let installPath = runner.installPath {
                    infoRow(label: "Install path", value: installPath, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                infoRow(label: "Work folder", value: runner.workFolder ?? "_work")
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No")
                if !runner.labels.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Labels", value: runner.labels.joined(separator: ", "))
                }
                if let group = runner.runnerGroup {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Runner group", value: group)
                }
                Divider().padding(.leading, RBSpacing.md)
                infoRow(label: "Status", value: runner.displayStatus)
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
                        Text("Labels")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
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
                        Text("Work folder")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
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
                        Text("Disable auto-update")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 130, alignment: .leading).fixedSize()
                        Spacer()
                        Toggle("", isOn: $disableUpdate)
                            .toggleStyle(.switch).labelsHidden()
                            .onChange(of: disableUpdate) { _ in saveDisableUpdate() }
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    saveStateRow(disableUpdateSaveState, restartNote: true)
                }
            }
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Proxy URL")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
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
                        Text("Proxy user")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
                        TextField("username", text: $proxyUser)
                            .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 7)
                    Divider().padding(.leading, RBSpacing.md)
                    HStack {
                        Text("Proxy pass")
                            .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading).fixedSize()
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
                        action: .rename,
                        description: "De-registers and re-registers the runner with a new name."
                    )
                    Divider().padding(.leading, RBSpacing.md)
                    dangerActionRow(
                        action: .move,
                        description: "De-registers and re-registers under a new GitHub repo or org."
                    )
                    Divider().padding(.leading, RBSpacing.md)
                    dangerActionRow(
                        action: .toggleEphemeral,
                        description: runner.isEphemeral
                            ? "Disable ephemeral mode — runner persists across jobs."
                            : "Enable ephemeral mode — runner de-registers after each job."
                    )
                    Divider().padding(.leading, RBSpacing.md)
                    dangerActionRow(
                        action: .changeGroup,
                        description: "Re-registers the runner in a different org runner group."
                    )
                    Divider().padding(.leading, RBSpacing.md)
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

            if action.requiresReregistration {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(Color.rbWarning)
                    Text("This will de-register and re-register the runner. The runner will be offline briefly.")
                        .font(.caption2)
                        .foregroundColor(Color.rbTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch action {
            case .rename:
                VStack(alignment: .leading, spacing: 4) {
                    Text("New runner name").font(.caption).foregroundColor(Color.rbTextSecondary)
                    TextField(runner.runnerName, text: $dangerInputA)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            case .move:
                VStack(alignment: .leading, spacing: 4) {
                    Text("New GitHub scope (owner/repo or org)").font(.caption).foregroundColor(Color.rbTextSecondary)
                    TextField("e.g. myorg/myrepo", text: $dangerInputA)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            case .toggleEphemeral:
                Text(runner.isEphemeral
                    ? "Ephemeral mode will be disabled. The runner will persist across jobs after re-registration."
                    : "Ephemeral mode will be enabled. The runner will de-register itself after each job."
                )
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
            case .changeGroup:
                VStack(alignment: .leading, spacing: 4) {
                    Text("New runner group name").font(.caption).foregroundColor(Color.rbTextSecondary)
                    TextField(runner.runnerGroup ?? "Default", text: $dangerInputA)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            case .remove:
                Text("This will de-register \"\(runner.runnerName)\" from GitHub and remove it from the list. The runner binary remains on disk.")
                    .font(.system(size: 12))
                    .foregroundColor(Color.rbTextSecondary)
            }

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
                    dangerInputA = ""
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
                    .tint(action.destructive ? Color.rbDanger : .accentColor)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    // MARK: - Danger Zone Trigger & Execute

    private func triggerDangerAction(_ action: DangerAction) {
        dangerInputA = ""
        dangerActionState = .idle
        pendingDangerAction = action
    }

    private func executeDangerAction(_ action: DangerAction) {
        dangerActionState = .saving
        switch action {
        case .rename:
            let newName = dangerInputA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else {
                dangerActionState = .failure("Runner name cannot be empty")
                return
            }
            performReregister(newName: newName, newScope: nil, ephemeral: nil, runnerGroup: nil)
        case .move:
            let newScope = dangerInputA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newScope.isEmpty else {
                dangerActionState = .failure("GitHub scope cannot be empty")
                return
            }
            performReregister(newName: nil, newScope: newScope, ephemeral: nil, runnerGroup: nil)
        case .toggleEphemeral:
            performReregister(newName: nil, newScope: nil, ephemeral: !runner.isEphemeral, runnerGroup: nil)
        case .changeGroup:
            let group = dangerInputA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !group.isEmpty else {
                dangerActionState = .failure("Runner group cannot be empty")
                return
            }
            performReregister(newName: nil, newScope: nil, ephemeral: nil, runnerGroup: group)
        case .remove:
            performRemove()
        }
    }

    private func performReregister(
        newName: String?,
        newScope: String?,
        ephemeral: Bool?,
        runnerGroup: String?
    ) {
        guard let currentScope = scopeFromHtmlUrl(runner.gitHubUrl) else {
            dangerActionState = .failure("Cannot determine current GitHub scope from runner URL")
            return
        }
        guard let installPath = runner.installPath else {
            dangerActionState = .failure("Install path unknown")
            return
        }
        let targetName  = newName    ?? runner.runnerName
        let targetScope = newScope   ?? currentScope
        let targetEph   = ephemeral  ?? runner.isEphemeral
        let targetGroup = runnerGroup ?? runner.runnerGroup

        DispatchQueue.global(qos: .userInitiated).async {
            if runner.isRunning {
                _ = RunnerLifecycleService.shared.stop(runner: runner)
            }
            guard let removalToken = fetchRemovalToken(scope: currentScope) else {
                DispatchQueue.main.async { dangerActionState = .failure("Failed to fetch removal token from GitHub") }
                return
            }
            let removeSh = installPath + "/config.sh"
            let removeResult = Shell.run("\"\(removeSh)\" remove --token \(removalToken)", timeout: 60)
            log("performReregister › remove exit=\(removeResult.exitCode) output=\(removeResult.output.prefix(200))")
            guard let regToken = fetchRegistrationToken(scope: targetScope) else {
                DispatchQueue.main.async { dangerActionState = .failure("Failed to fetch registration token for \(targetScope)") }
                return
            }
            var configArgs = [
                "\"\(removeSh)\"",
                "--url", "https://github.com/\(targetScope)",
                "--token", regToken,
                "--name", "\"\(targetName)\"",
                "--unattended",
                "--replace"
            ]
            if targetEph { configArgs += ["--ephemeral"] }
            if let group = targetGroup, !group.isEmpty {
                configArgs += ["--runnergroup", "\"\(group)\""]
            }
            let configResult = Shell.run(configArgs.joined(separator: " "), timeout: 60)
            log("performReregister › config exit=\(configResult.exitCode) output=\(configResult.output.prefix(200))")
            let success = configResult.exitCode == 0
            DispatchQueue.main.async {
                if success {
                    dangerActionState = .success
                    LocalRunnerStore.shared.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        pendingDangerAction = nil
                        dangerInputA = ""
                    }
                } else {
                    dangerActionState = .failure(
                        "config.sh exited \(configResult.exitCode). Check logs."
                    )
                }
            }
        }
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
            disableUpdate = json["disableUpdate"] as? Bool ?? false
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

    private func saveDisableUpdate() {
        guard let installPath = runner.installPath else {
            disableUpdateSaveState = .failure("Install path unknown"); return
        }
        disableUpdateSaveState = .saving
        let value = disableUpdate
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = patchRunnerJSON(installPath: installPath, key: "disableUpdate", boolValue: value)
            DispatchQueue.main.async {
                disableUpdateSaveState = ok ? .success : .failure("Failed to write .runner JSON")
                if ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if disableUpdateSaveState == .success { disableUpdateSaveState = .idle }
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
