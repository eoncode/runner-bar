// AddRunnerSheet.swift
// RunnerBar
import AppKit
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - AddRunnerSheet

// MARK: - URI Constants
/// Enumerates possible values for GitHubURIs.
private enum GitHubURIs {
    /// The base constant.
    static let base            = "https://github.com/"
    /// The apiRunnerLatest constant.
    static let apiRunnerLatest = "https://api.github.com/repos/actions/runner/releases/latest"
    /// The launchAgentsDir constant.
    static let launchAgentsDir = "Library/LaunchAgents"
    /// The actionsRunnerDefaultDir constant.
    static let actionsRunnerDefaultDir = "actions-runner/my-runner"
}

/// Sheet view for onboarding a self-hosted runner.
///
/// Supports two modes selectable via a segmented control at the top:
///
/// - **Add new**: downloads, configures and registers a brand-new runner with GitHub.
/// - **Add pre-existing**: imports a runner folder that was already configured outside
///   of RunnerBar (e.g. via terminal). Only writes the LaunchAgent plist so
///   the runner can be managed — no token or download needed.
///
/// After successful registration/import the app writes a minimal LaunchAgent plist to
/// `~/Library/LaunchAgents/actions.runner.<owner>.<repo>.<name>.plist` directly
/// via FileManager, and registers the runner in `LocalRunnerStore`.
///
/// Requires a GitHub token for "Add new" only (`gh auth login`, GH_TOKEN, or GITHUB_TOKEN).
struct AddRunnerSheet: View {
    /// The isPresented property.
    @Binding var isPresented: Bool
    /// The onComplete constant.
    let onComplete: () -> Void

    // MARK: - Add Mode

    /// Controls which form body is shown in the sheet.
    enum AddMode: String, CaseIterable, Identifiable {
        /// Coding key for the `addNew` field.
        case addNew      = "Add new"
        /// Coding key for the `addExisting` field.
        case addExisting = "Add pre-existing"
        /// The id property.
        var id: String { rawValue }
    }

    /// The addMode property.
    @State private var addMode: AddMode = .addNew

    // MARK: Scope state (Add new only)

    /// Determines whether the runner is registered at repo or organisation scope.
    enum ScopeType: String, CaseIterable, Identifiable {
        /// Coding key for the `repo` field.
        case repo = "Repository"
        /// Coding key for the `org` field.
        case org  = "Organisation"
        /// The id property.
        var id: String { rawValue }
    }

    /// The scopeType property.
    @State private var scopeType: ScopeType = .repo
    /// The selectedRepo property.
    @State private var selectedRepo = ""
    /// The selectedOrg property.
    @State private var selectedOrg  = ""
    /// The repos property.
    @State private var repos: [String] = []
    /// The orgs property.
    @State private var orgs:  [String] = []
    /// The isLoadingScopes property.
    @State private var isLoadingScopes = false
    /// The showRepoSelector property.
    @State private var showRepoSelector = false
    /// The showOrgSelector property.
    @State private var showOrgSelector  = false

    // MARK: Runner config state (Add new only)

    /// The runnerName property.
    @State private var runnerName = ""
    /// The labelsText property.
    @State private var labelsText = "self-hosted,macOS"
    /// Default: ~/actions-runner/my-runner — user should rename the last
    /// component to match their runner name. Each runner needs its own folder.
    @State private var installDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path

    // MARK: Registration state (Add new only)

    /// The isRegistering property.
    @State private var isRegistering    = false
    /// The registrationStep property.
    @State private var registrationStep = ""
    /// The errorMessage property.
    @State private var errorMessage: String?

    // MARK: Pre-existing state (Add pre-existing only)

    /// The folder path the user selected via NSOpenPanel.
    @State private var existingDir = ""
    /// Runner name parsed from the `.runner` JSON inside `existingDir`.
    @State private var detectedName = ""
    /// GitHub URL parsed from the `.runner` JSON inside `existingDir`.
    @State private var detectedGitHubURL = ""
    /// Shown when the selected folder has no valid `.runner` file or it can’t be parsed.
    @State private var existingError: String?
    /// Editable fallback shown when `.runner` JSON has no `gitHubUrl` (rare, org-scoped runners).
    @State private var githubURLOverride = ""
    /// Whether a plist already exists for this runner name (duplicate detection).
    @State private var isDuplicate = false

    // MARK: - Body

    /// The body property.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add runner").font(.headline)

            // MARK: Mode toggle
            Picker("Mode", selection: $addMode) {
                ForEach(AddMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: addMode) { _, _ in
                resetAddNewState()
                resetExistingState()
            }

            Divider()

            // MARK: Form body branch
            if addMode == .addNew {
                addNewFormBody
            } else {
                addExistingFormBody
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if addMode == .addNew { loadScopes() }
        }
    }

    // MARK: - Add New Form Body

    /// Form fields shown when the user selects the "Add new" mode:
    /// scope picker, repo/org selector, token field, runner name, and install path.
    @ViewBuilder
    private var addNewFormBody: some View {
        Picker("Scope", selection: $scopeType) {
            ForEach(ScopeType.allCases) { s in Text(s.rawValue).tag(s) }
        }
        .pickerStyle(.segmented)

        if isLoadingScopes {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text("Loading…").font(.caption).foregroundColor(.secondary)
            }
        } else if scopeType == .repo {
            selectorButton(
                label: "Repository",
                selection: selectedRepo,
                action: { showRepoSelector = true }
            )
            .sheet(isPresented: $showRepoSelector) {
                RepoSelectorSheet(
                    items: repos,
                    label: "Repository",
                    onDismiss: { showRepoSelector = false },
                    onSelect: { item in
                        selectedRepo = item
                        showRepoSelector = false
                    }
                )
            }
        } else {
            selectorButton(
                label: "Organisation",
                selection: selectedOrg,
                action: { showOrgSelector = true }
            )
            .sheet(isPresented: $showOrgSelector) {
                RepoSelectorSheet(
                    items: orgs,
                    label: "Organisation",
                    onDismiss: { showOrgSelector = false },
                    onSelect: { item in
                        selectedOrg = item
                        showOrgSelector = false
                    }
                )
            }
        }

        labeledField("Runner name", placeholder: "e.g. my-mac-runner", text: $runnerName)
        labeledField(
            "Labels (comma-separated)",
            placeholder: "e.g. self-hosted,macOS,arm64",
            text: $labelsText
        )

        VStack(alignment: .leading, spacing: 4) {
            Text("Runner install directory").font(.caption).foregroundColor(.secondary)
            TextField("", text: $installDir)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text(
                "Each runner needs its own unique folder. Use the runner name as the last path component, e.g. ~/actions-runner/my-runner."
            )
            .font(.caption2)
            .foregroundColor(.secondary)
            if dirAlreadyConfigured {
                Label(
                    "This folder already has a runner configured. Choose a different path.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundColor(.orange)
            }
        }

        if isRegistering && !registrationStep.isEmpty {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(registrationStep).font(.caption).foregroundColor(.secondary)
            }
        }

        if let err = errorMessage {
            Text(err)
                .font(.caption).foregroundColor(.red)
                .padding(8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
        }

        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .disabled(isRegistering)
            // swiftlint:disable:next multiple_closures_with_trailing_closure
            Button(action: { Task { await register() } }) {
                if isRegistering {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                        Text("Registering…")
                    }
                } else {
                    Text("Add new runner")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRegister || isRegistering)
        }
    }

    // MARK: - Add Pre-Existing Form Body

    /// Form fields shown when the user selects the "Add pre-existing" mode:
    /// folder picker, detected runner name, and GitHub URL display/override.
    @ViewBuilder
    private var addExistingFormBody: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Folder picker row
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner install folder").font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(existingDir.isEmpty ? "No folder selected" : existingDir)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(existingDir.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { pickExistingFolder() }
                        .controlSize(.small)
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            // Detected fields (shown once a valid folder is picked)
            if !detectedName.isEmpty {
                labeledReadOnly("Runner name (detected)", value: detectedName)

                if detectedGitHubURL.isEmpty {
                    // Fallback: let user supply the GitHub URL manually
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub URL").font(.caption).foregroundColor(.secondary)
                        TextField("\(GitHubURIs.base)owner/repo", text: $githubURLOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text("The .runner file has no GitHub URL. Paste the repo or org URL above.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    labeledReadOnly("GitHub URL (detected)", value: detectedGitHubURL)
                }
            }

            // Error state
            if let err = existingError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }

            // Duplicate warning
            if isDuplicate {
                Label(
                    "This runner is already tracked by RunnerBar.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Import Runner", action: importExistingRunner)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
    }

    // MARK: - Sub-views

    /// Selector button that opens the searchable RepoSelectorSheet.
    @ViewBuilder
    private func selectorButton(label: String, selection: String,
                                action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Button(action: action) {
                HStack {
                    Text(selection.isEmpty ? "— select —" : selection)
                        .font(.system(size: 12))
                        .foregroundColor(selection.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            if selection.isEmpty {
                Text("No \(label.lowercased())s found. Run `gh auth login` or set GH_TOKEN.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// Helper that renders a caption label above a `TextField` with rounded-border style.
    @ViewBuilder
    private func labeledField(_ title: String, placeholder: String,
                              text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    /// Read-only display field used in the pre-existing form.
    @ViewBuilder
    private func labeledReadOnly(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    // MARK: - Helpers (Add new)

    /// The effectiveScope property.
    private var effectiveScope: String { scopeType == .repo ? selectedRepo : selectedOrg }

    /// Returns `true` when the chosen install directory already contains a `.runner` file,
    /// preventing accidental double-registration of the same path.
    private var dirAlreadyConfigured: Bool {
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
        )
    }

    /// Guards the Register button: requires a non-empty runner name, a selected scope,
    /// and an install directory that has not already been configured.
    private var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !effectiveScope.isEmpty
            && !dirAlreadyConfigured
    }

    // MARK: - Helpers (Add pre-existing)

    /// The GitHub URL to use for the import: detected from .runner or the manual override.
    private var effectiveGitHubURL: String {
        detectedGitHubURL.isEmpty ? githubURLOverride.trimmingCharacters(in: .whitespaces)
                                  : detectedGitHubURL
    }

    /// Guards the Import button: requires a detected runner name, no parse error,
    /// no duplicate plist, and a non-empty GitHub URL.
    private var canImport: Bool {
        !detectedName.isEmpty
            && existingError == nil
            && !isDuplicate
            && !effectiveGitHubURL.isEmpty
    }

    /// Checks whether a LaunchAgent plist already exists for this runner name.
    private func checkDuplicate(runnerName: String) -> Bool {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(GitHubURIs.launchAgentsDir).path
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: launchAgentsDir) else { return false }
        return entries.contains {
            $0.hasPrefix("actions.runner.") && $0.contains(".".appending(runnerName) + ".plist")
        }
    }

    // MARK: - Actions (Add pre-existing)

    /// Opens an `NSOpenPanel` to let the user select a pre-configured runner directory.
    private func pickExistingFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Select the runner install folder (must contain a .runner file)"
        openPanel.prompt = "Select"
        guard let window = NSApp.keyWindow else { return }
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        openPanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = openPanel.url else { return }
            handlePickedFolder(url)
        }
    }

    /// Validates the picked folder and populates the detected-runner state.
    private func handlePickedFolder(_ url: URL) {
        resetExistingState()
        existingDir = url.path

        let runnerFileURL = url.appendingPathComponent(".runner")
        guard FileManager.default.fileExists(atPath: runnerFileURL.path) else {
            existingError = "No .runner file found in the selected folder. Is this a valid runner install directory?"
            return
        }

        guard let data = try? Data(contentsOf: runnerFileURL) else {
            existingError = "Could not read .runner file."
            return
        }

        struct RunnerJSON: Decodable {
            let gitHubUrl: String?
            let runnerName: String?
        }

        guard let json = try? JSONDecoder().decode(RunnerJSON.self, from: data) else {
            existingError = "Could not parse .runner file. It may be malformed."
            return
        }

        detectedName = json.runnerName ?? url.lastPathComponent
        detectedGitHubURL = json.gitHubUrl ?? ""
        isDuplicate = checkDuplicate(runnerName: detectedName)

        log("AddRunnerSheet › pre-existing: name=\(detectedName) url=\(detectedGitHubURL) duplicate=\(isDuplicate)")
    }

    /// Writes the LaunchAgent plist, registers with LocalRunnerStore, and dismisses.
    private func importExistingRunner() {
        guard canImport else { return }

        let scope = effectiveGitHubURL
            .replacingOccurrences(of: GitHubURIs.base, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !scope.isEmpty else {
            existingError = "Could not derive a scope from the GitHub URL. Please check the URL."
            return
        }

        writeLaunchAgentPlist(
            scope: scope,
            runnerName: detectedName,
            workingDirectory: existingDir
        )
        LocalRunnerStore.shared.add(runnerName: detectedName, installPath: existingDir)

        isPresented = false
        onComplete()
    }

    // MARK: - State reset helpers

    /// Resets all "Add new" form fields to their default values.
    private func resetAddNewState() {
        runnerName       = ""
        labelsText       = "self-hosted,macOS"
        installDir       = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path
        isRegistering    = false
        registrationStep = ""
        errorMessage     = nil
        scopeType        = .repo
        selectedRepo     = repos.first ?? ""
        selectedOrg      = orgs.first  ?? ""
        if addMode == .addNew && repos.isEmpty && orgs.isEmpty {
            loadScopes()
        }
    }

    /// Clears all "Add pre-existing" detection state so a fresh folder can be picked.
    private func resetExistingState() {
        existingDir       = ""
        detectedName      = ""
        detectedGitHubURL = ""
        existingError     = nil
        githubURLOverride = ""
        isDuplicate       = false
    }

    // MARK: - Scopes loader

    /// Fetches the user’s repos and organisations on a background thread.
    private func loadScopes() {
        isLoadingScopes = true
        Task.detached(priority: .userInitiated) {
            let fetchedRepos = fetchUserRepos()
            let fetchedOrgs  = fetchUserOrgs()
            await MainActor.run {
                repos = fetchedRepos
                orgs  = fetchedOrgs
                if let first = fetchedRepos.first { selectedRepo = first }
                if let first = fetchedOrgs.first  { selectedOrg  = first }
                isLoadingScopes = false
            }
        }
    }

    /// Updates `registrationStep` on the main thread.
    @MainActor private func setStep(_ msg: String) {
        registrationStep = msg
    }

    // MARK: - Register (Add new)

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    /// Downloads, unpacks, configures a new runner, registers with LocalRunnerStore, and dismisses.
    private func register() async {
        guard canRegister else { return }
        errorMessage = nil
        registrationStep = ""
        isRegistering = true
        let scope  = effectiveScope
        let name   = runnerName.trimmingCharacters(in: .whitespaces)
        let labels = labelsText.trimmingCharacters(in: .whitespaces)
        let dir    = installDir.trimmingCharacters(in: .whitespaces)

        await Task.detached(priority: .userInitiated) {
            let homeDir     = FileManager.default.homeDirectoryForCurrentUser
                .resolvingSymlinksInPath().path
            let resolvedDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
                await MainActor.run {
                    isRegistering = false
                    errorMessage  = "Install directory must be inside your home folder (~/…)."
                }
                return
            }

            let runnerFile = URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
            if FileManager.default.fileExists(atPath: runnerFile) {
                await MainActor.run { isRegistering = false }
                return
            }

            do {
                try FileManager.default.createDirectory(atPath: dir,
                                                        withIntermediateDirectories: true)
            } catch {
                await MainActor.run {
                    isRegistering = false
                    errorMessage  = "Failed to create directory: \(error.localizedDescription)"
                }
                return
            }

            let configPath = URL(fileURLWithPath: dir).appendingPathComponent("config.sh").path

            if !FileManager.default.fileExists(atPath: configPath) {
                await setStep("Downloading runner package…")
                guard let downloadURL = fetchRunnerDownloadURL() else {
                    await MainActor.run {
                        isRegistering = false
                        errorMessage  = "Could not determine runner download URL. Check your internet connection."
                    }
                    return
                }
                let tarPath = URL(fileURLWithPath: dir)
                    .appendingPathComponent("actions-runner.tar.gz").path
                guard runSimpleProcess("/usr/bin/curl",
                                      args: ["-sL", downloadURL, "-o", tarPath]) == 0 else {
                    await MainActor.run { isRegistering = false; errorMessage = "Download failed." }
                    return
                }
                await setStep("Unpacking runner package…")
                let tarExit = runSimpleProcess("/usr/bin/tar", args: ["xzf", tarPath, "-C", dir])
                try? FileManager.default.removeItem(atPath: tarPath)
                guard tarExit == 0 else {
                    await MainActor.run { isRegistering = false; errorMessage = "Unpack failed." }
                    return
                }
            }

            await setStep("Fetching registration token…")
            guard let token = fetchRegistrationToken(scope: scope) else {
                await MainActor.run {
                    isRegistering = false
                    errorMessage  = "Failed to fetch registration token. Ensure `gh auth login` has been run or GH_TOKEN is set."
                }
                return
            }

            await setStep("Configuring runner…")
            let ghURL      = "\(GitHubURIs.base)\(scope)"
            let configExit = runRegistrationCommand(dir: dir, ghURL: ghURL,
                                                    token: token, name: name, labels: labels)
            guard configExit == 0 else {
                await MainActor.run {
                    isRegistering = false
                    errorMessage  = "config.sh failed (exit \(configExit)). Check the token is valid and the runner name is unique."
                }
                return
            }

            await setStep("Registering service…")
            writeLaunchAgentPlist(scope: scope, runnerName: name, workingDirectory: dir)

            await MainActor.run {
                LocalRunnerStore.shared.add(runnerName: name, installPath: dir)
                isRegistering    = false
                registrationStep = ""
                isPresented      = false
                onComplete()
            }
        }.value
    }

    // MARK: - Plist writer (shared by both modes)

    /// Writes a minimal LaunchAgent plist to `~/Library/LaunchAgents/`.
    nonisolated func writeLaunchAgentPlist(scope: String, runnerName: String, workingDirectory: String) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(GitHubURIs.launchAgentsDir)
        let scopeParts = scope.components(separatedBy: "/")
        let owner      = scopeParts[0]
        let repo       = scopeParts.count > 1 ? scopeParts[1] : scopeParts[0]
        let label      = "actions.runner.\(owner).\(repo).\(runnerName)"
        let plistURL   = launchAgentsDir.appendingPathComponent("\(label).plist")

        do {
            try FileManager.default.createDirectory(
                at: launchAgentsDir, withIntermediateDirectories: true)
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: ["Label": label, "WorkingDirectory": workingDirectory],
                format: .xml,
                options: 0
            )
            try plistData.write(to: plistURL, options: .atomic)
            log("AddRunnerSheet › wrote LaunchAgent plist: \(plistURL.path)")
        } catch {
            log("AddRunnerSheet › failed to write LaunchAgent plist: \(error)")
        }
    }

    // MARK: - Process helpers (Add new)

    /// Invokes `config.sh` with the GitHub URL, registration token, runner name and labels.
    nonisolated private func runRegistrationCommand(
        dir: String, ghURL: String, token: String, name: String, labels: String
    ) -> Int32 {
        let configURL = URL(fileURLWithPath: dir).appendingPathComponent("config.sh")
        let task = Process()
        task.executableURL       = configURL
        task.currentDirectoryURL = URL(fileURLWithPath: dir)
        var args = ["--url", ghURL, "--token", token, "--name", name, "--unattended"]
        if !labels.isEmpty { args += ["--labels", labels] }
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe
        nonisolated(unsafe) var outputData = Data()
        let lock = NSLock()
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outputData.append(chunk); lock.unlock()
        }
        do { try task.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("runRegistrationCommand › launch error: \(error)")
            return 1
        }
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
        log("runRegistrationCommand › exit=\(task.terminationStatus): \((String(data: outputData, encoding: .utf8) ?? "").prefix(500))")
        return task.terminationStatus
    }

    /// Launches `executable` with `args` synchronously and returns the termination status.
    nonisolated private func runSimpleProcess(_ executable: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL  = URL(fileURLWithPath: executable)
        task.arguments      = args
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        do { try task.run() } catch {
            log("runSimpleProcess › \(executable) launch error: \(error)")
            return 1
        }
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        log("runSimpleProcess › \(executable) exit \(task.terminationStatus)")
        return task.terminationStatus
    }
}

// MARK: - Runner download URL

/// Queries the GitHub API for the latest macOS runner release and returns the `.tar.gz` download URL
/// matching the current CPU architecture (`arm64` or `x64`).
private func fetchRunnerDownloadURL() -> String? {
    let archTask = Process()
    archTask.executableURL  = URL(fileURLWithPath: "/usr/bin/uname")
    archTask.arguments      = ["-m"]
    let archPipe = Pipe()
    archTask.standardOutput = archPipe
    archTask.standardError  = Pipe()
    guard (try? archTask.run()) != nil else { return nil }
    archTask.waitUntilExit()
    let archRaw   = archPipe.fileHandleForReading.readDataToEndOfFile()
    let arch      = String(data: archRaw, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let assetArch = (arch == "arm64") ? "arm64" : "x64"
    let assetName = "actions-runner-osx-\(assetArch)"
    log("fetchRunnerDownloadURL › arch=\(arch) assetName=\(assetName)")

    guard let url  = URL(string: GitHubURIs.apiRunnerLatest),
          let data = try? Data(contentsOf: url) else {
        log("fetchRunnerDownloadURL › failed to fetch release JSON")
        return nil
    }
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey {
            case name; case browserDownloadUrl = "browser_download_url"
        }
    }
    struct Release: Decodable { let assets: [Asset] }
    guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
        log("fetchRunnerDownloadURL › decode failed")
        return nil
    }
    let match = release.assets.first {
        $0.name.hasPrefix(assetName) && $0.name.hasSuffix(".tar.gz")
    }
    log("fetchRunnerDownloadURL › match=\(match?.name ?? "nil")")
    return match?.browserDownloadUrl
}
// swiftlint:enable type_body_length
