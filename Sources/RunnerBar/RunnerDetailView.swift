import AppKit
import SwiftUI

// MARK: - RunnerDetailView
// Navigation level: SettingsView (runner row tap) → RunnerDetailView ← this view
//
// Displays a read-only info block and editable config fields for a locally-installed runner.
// Read-only info: GitHub URL, agent ID, OS/arch, version, install path, work folder, ephemeral, labels, status.
// Editable config (#492): Labels (GitHub API), work folder, disable auto-update, proxy URL, proxy credentials.
// Danger Zone (#493): rename, move, ephemeral toggle, runner group change, remove.

// MARK: - Save state helper
private enum SaveState: Equatable {
    case idle
    case saving
    case success
    case failure(String)
}

struct RunnerDetailView: View {
    let runner: RunnerModel
    let onBack: () -> Void

    // Kept as @State so Start/Stop can optimistically update the row.
    @State private var isRunning: Bool
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    // MARK: - Editable field state (#492)

    // Labels (GitHub API — no restart needed)
    @State private var labelsText: String
    @State private var labelsSaveState: SaveState = .idle

    // Work folder (.runner JSON — restart needed)
    @State private var workFolderText: String
    @State private var workFolderSaveState: SaveState = .idle

    // Disable auto-update (.runner JSON — restart needed)
    @State private var disableUpdate: Bool
    @State private var disableUpdateSaveState: SaveState = .idle

    // Proxy URL (.proxy file — restart needed)
    @State private var proxyUrl: String
    @State private var proxyUrlSaveState: SaveState = .idle

    // Proxy credentials (.proxycredentials file — restart needed)
    @State private var proxyUser: String
    @State private var proxyPassword: String
    @State private var proxyCreditsSaveState: SaveState = .idle

    init(runner: RunnerModel, onBack: @escaping () -> Void) {
        self.runner = runner
        self.onBack = onBack
        self._isRunning = State(initialValue: runner.isRunning)
        // Seed editable fields from model
        self._labelsText = State(initialValue: runner.labels
            .filter { !["self-hosted"].contains($0) && !$0.lowercased().contains("x64")
                && !$0.lowercased().contains("arm64") && !$0.lowercased().contains("linux")
                && !$0.lowercased().contains("macos") && !$0.lowercased().contains("windows") }
            .joined(separator: ", ")
        )
        self._workFolderText = State(initialValue: runner.workFolder ?? "_work")
        self._disableUpdate = State(initialValue: false) // loaded from .runner JSON below
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

            // Status dot + name
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(runner.runnerName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            // Start / Stop
            if isRunning {
                Button(action: stopRunner) {
                    Text("Stop").font(.caption2)
                }
                .buttonStyle(.bordered)
                .help("Stop runner service")
            } else {
                Button(action: startRunner) {
                    Text("Start").font(.caption2)
                }
                .buttonStyle(.bordered)
                .help("Start runner service")
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
                // GitHub URL
                if let url = runner.gitHubUrl {
                    infoRow(label: "GitHub URL", value: url, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Agent ID
                if let agentId = runner.agentId {
                    infoRow(label: "Agent ID", value: String(agentId))
                    Divider().padding(.leading, RBSpacing.md)
                }
                // OS / Architecture
                let osArch = [runner.platform, runner.platformArchitecture]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                if !osArch.isEmpty {
                    infoRow(label: "OS / Arch", value: osArch)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Runner version
                if let version = runner.agentVersion {
                    infoRow(label: "Version", value: version)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Install path
                if let installPath = runner.installPath {
                    infoRow(label: "Install path", value: installPath, copyable: true)
                    Divider().padding(.leading, RBSpacing.md)
                }
                // Work folder (read-only here; editable in config section)
                infoRow(label: "Work folder", value: runner.workFolder ?? "_work")
                Divider().padding(.leading, RBSpacing.md)
                // Ephemeral mode
                infoRow(label: "Ephemeral", value: runner.isEphemeral ? "Yes" : "No")
                // Labels (read-only here; editable in config section)
                if !runner.labels.isEmpty {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Labels", value: runner.labels.joined(separator: ", "))
                }
                // Runner group (populated via GitHub API by RunnerStatusEnricher)
                if let group = runner.runnerGroup {
                    Divider().padding(.leading, RBSpacing.md)
                    infoRow(label: "Runner group", value: group)
                }
                Divider().padding(.leading, RBSpacing.md)
                // Status
                infoRow(label: "Status", value: runner.displayStatus)
            }
        }
    }

    // MARK: - Config Section (#492)

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Configuration")

            // Labels — saved immediately via GitHub API, no restart needed
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Labels")
                            .font(.system(size: 12))
                            .foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading)
                            .fixedSize()
                        TextField("comma-separated", text: $labelsText)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity)
                        saveButton(state: labelsSaveState, action: saveLabels)
                    }
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 7)
                    saveStateRow(labelsSaveState, restartNote: false)
                }
            }

            // Work folder — restart needed
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Work folder")
                            .font(.system(size: 12))
                            .foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading)
                            .fixedSize()
                        TextField("_work", text: $workFolderText)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity)
                        saveButton(state: workFolderSaveState, action: saveWorkFolder)
                    }
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 7)
                    saveStateRow(workFolderSaveState, restartNote: true)
                }
            }

            // Disable auto-update — restart needed
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Disable auto-update")
                            .font(.system(size: 12))
                            .foregroundColor(Color.rbTextSecondary)
                            .frame(width: 130, alignment: .leading)
                            .fixedSize()
                        Spacer()
                        Toggle("", isOn: $disableUpdate)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: disableUpdate) { _ in saveDisableUpdate() }
                    }
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 7)
                    saveStateRow(disableUpdateSaveState, restartNote: true)
                }
            }

            // Proxy URL — restart needed
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Proxy URL")
                            .font(.system(size: 12))
                            .foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading)
                            .fixedSize()
                        TextField("http://proxy:8080", text: $proxyUrl)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity)
                        saveButton(state: proxyUrlSaveState, action: saveProxyUrl)
                    }
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 7)
                    saveStateRow(proxyUrlSaveState, restartNote: true)
                }
            }

            // Proxy credentials — restart needed
            infoCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Proxy user")
                            .font(.system(size: 12))
                            .foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading)
                            .fixedSize()
                        TextField("username", text: $proxyUser)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 7)
                    Divider().padding(.leading, RBSpacing.md)
                    HStack {
                        Text("Proxy pass")
                            .font(.system(size: 12))
                            .foregroundColor(Color.rbTextSecondary)
                            .frame(width: 100, alignment: .leading)
                            .fixedSize()
                        SecureField("password", text: $proxyPassword)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity)
                        saveButton(state: proxyCreditsSaveState, action: saveProxyCredentials)
                    }
                    .padding(.horizontal, RBSpacing.md)
                    .padding(.vertical, 7)
                    saveStateRow(proxyCreditsSaveState, restartNote: true)
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
                .font(.system(size: 13))
                .foregroundColor(Color.rbSuccess)
                .frame(width: 28)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(Color.rbDanger)
                .frame(width: 28)
        default:
            Button(action: action) {
                Text("Save").font(.caption2)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func saveStateRow(_ state: SaveState, restartNote: Bool) -> some View {
        if restartNote, state == .success {
            Text("Changes take effect after the next runner restart.")
                .font(.caption2)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md)
                .padding(.bottom, 6)
        } else if case .failure(let msg) = state {
            Text(msg)
                .font(.caption2)
                .foregroundColor(Color.rbDanger)
                .padding(.horizontal, RBSpacing.md)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Sub-view helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(RBFont.sectionHeader)
            .foregroundColor(Color.rbTextSecondary)
            .padding(.horizontal, RBSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: RBRadius.small)
                .fill(Color.rbSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.small)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, RBSpacing.md)
        .padding(.bottom, 8)
    }

    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.rbTextSecondary)
                .frame(width: 100, alignment: .leading)
                .fixedSize()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.rbTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .help("Copy to clipboard")
            }
        }
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 7)
    }

    // MARK: - Dot color

    private var dotColor: Color {
        switch runner.statusColor {
        case .running: return Color.rbSuccess
        case .busy:    return Color.rbWarning
        case .idle:    return Color.rbTextTertiary
        case .offline: return Color.rbDanger
        }
    }

    // MARK: - On Appear: load editable fields from disk

    private func loadEditableFields() {
        guard let installPath = runner.installPath else { return }
        // Load disableUpdate from .runner JSON
        let runnerJSONPath = installPath + "/.runner"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: runnerJSONPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            disableUpdate = json["disableUpdate"] as? Bool ?? false
        }
        // Load proxy URL from .proxy file
        let proxyFilePath = installPath + "/.proxy"
        proxyUrl = (try? String(contentsOfFile: proxyFilePath, encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        // Load proxy credentials from .proxycredentials file
        let credPath = installPath + "/.proxycredentials"
        if let credContent = try? String(contentsOfFile: credPath, encoding: .utf8) {
            // Format: user\npassword  (two lines)
            let lines = credContent.components(separatedBy: "\n")
            proxyUser = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            proxyPassword = lines.dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
    }

    // MARK: - Save Actions

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
            workFolderSaveState = .failure("Install path unknown")
            return
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
            disableUpdateSaveState = .failure("Install path unknown")
            return
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
            proxyUrlSaveState = .failure("Install path unknown")
            return
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
            proxyCreditsSaveState = .failure("Install path unknown")
            return
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

/// Reads the .runner JSON at `installPath/.runner`, mutates a single key, and writes it back.
/// Thread-safe: call from a background queue. Returns true on success.
private func patchRunnerJSON(installPath: String, key: String, stringValue: String? = nil, boolValue: Bool? = nil) -> Bool {
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
