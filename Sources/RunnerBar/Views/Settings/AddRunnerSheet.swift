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
    static let base            = "https://github.com/" // NOSONAR — centralised constant, not an inline hardcoded URI
    /// The apiRunnerLatest constant.
    static let apiRunnerLatest = "https://api.github.com/repos/actions/runner/releases/latest" // NOSONAR — centralised constant, not an inline hardcoded URI
    /// The launchAgentsDir constant.
    static let launchAgentsDir = "Library/LaunchAgents"
    /// The actionsRunnerDefaultDir constant.
    static let actionsRunnerDefaultDir = "actions-runner/my-runner"
    /// System path to the curl binary used when downloading the runner package.
    static let curlPath  = "/usr/bin/curl" // NOSONAR — fixed OS path
    /// System path to the tar binary used when unpacking the runner package.
    static let tarPath   = "/usr/bin/tar"  // NOSONAR — fixed OS path
    /// System path to the uname binary used to detect CPU architecture.
    static let unamePath = "/usr/bin/uname" // NOSONAR — fixed OS path
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
/// Requires a GitHub token for "Add new" (OAuth sign-in, GH_TOKEN, or GITHUB_TOKEN).
struct AddRunnerSheet: View {
    /// Controls whether the sheet is shown.
    @Binding var isPresented: Bool
    /// Called when registration or import completes successfully.
    let onComplete: () -> Void

    // MARK: - Add Mode

    /// Controls which form body is shown in the sheet.
    enum AddMode: String, CaseIterable, Identifiable {
        /// Onboards a fresh runner via download + registration token.
        case addNew      = "Add new"
        /// Imports a runner folder that was configured outside of RunnerBar.
        case addExisting = "Add pre-existing"
        /// Stable identity backed by `rawValue`.
        var id: String { rawValue }
    }

    /// Whether the user is adding a new runner or importing a pre-existing one.
    @State private var addMode: AddMode = .addNew

    // MARK: Scope state (Add new only)

    /// Determines whether the runner is registered at repo or organisation scope.
    enum ScopeType: String, CaseIterable, Identifiable {
        /// Runner registered to a single repository.
        case repo = "Repository"
        /// Runner registered at organisation level.
        case org  = "Organisation"
        /// Stable identity backed by `rawValue`.
        var id: String { rawValue }
    }

    /// Whether the runner is repo-scoped or org-scoped.
    @State private var scopeType: ScopeType = .repo
    /// Selected repository slug (used when `scopeType == .repo`).
    @State private var selectedRepo = ""
    /// Selected organisation name (used when `scopeType == .org`).
    @State private var selectedOrg  = ""
    /// Repository slugs fetched from GitHub for the picker.
    @State private var repos: [String] = []
    /// Organisation names fetched from GitHub for the picker.
    @State private var orgs:  [String] = []
    /// `true` while scope options are being fetched from GitHub.
    @State private var isLoadingScopes = false
    /// `true` while the repository-selector sheet is presented.
    @State private var showRepoSelector = false
    /// `true` while the organisation-selector sheet is presented.
    @State private var showOrgSelector  = false

    // MARK: Runner config state (Add new only)

    /// Display name the runner will register with.
    @State private var runnerName = ""
    /// Comma-separated label string pre-populated with defaults.
    @State private var labelsText = "self-hosted,macOS"
    /// Default: ~/actions-runner/my-runner — user should rename the last
    /// component to match their runner name. Each runner needs its own folder.
    @State private var installDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path

    // MARK: Registration state (Add new only)

    /// `true` while the registration command is running.
    @State private var isRegistering    = false
    /// Human-readable description of the current registration step.
    @State private var registrationStep = ""
    /// Non-nil when registration fails; shown as an inline error.
    @State private var errorMessage: String?

    // MARK: Pre-existing state (Add pre-existing only)

    /// The folder path the user selected via NSOpenPanel.
    @State private var existingDir = ""
    /// Runner name parsed from the `.runner` JSON inside `existingDir`.
    @State private var detectedName = ""
    /// GitHub URL parsed from the `.runner` JSON inside `existingDir`.
    @State private var detectedGitHubURL = ""
    /// Shown when the selected folder has no valid `.runner` file or it can't be parsed.
    @State private var existingError: String?
    /// Editable fallback shown when `.runner` JSON has no `gitHubUrl` (rare, org-scoped runners).
    @State private var githubURLOverride = ""
    /// Whether a runner with this name is already in LocalRunnerStore's index.
    @State private var isDuplicate = false

    // MARK: - Body

    /// Root layout: mode picker, form body, and action bar.
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
                        // No dismiss here -- RepoSelectorSheet.itemRow calls onDismiss after onSelect.
                        selectedRepo = item
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
                        // No dismiss here -- RepoSelectorSheet.itemRow calls onDismiss after onSelect.
                        selectedOrg = item
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
            Button {
                // Actor isolation note: `Task { await register() }` does NOT inherit
                // @MainActor here. Swift's rule is that a Task inherits the *callee's*
                // actor isolation — not the call site's. `register()` carries no actor
                // annotation, so the Task runs on the cooperative thread pool regardless
                // of the fact that this button action fires from SwiftUI's @MainActor
                // body. See the full isolation rationale in register()'s doc comment.
                Task { await register() }
            } label: {
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
                    Button {
                        pickExistingFolder()
                    } label: {
                        Text("Choose…")
                    }
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
                Text("No \(label.lowercased())s found. Sign in with GitHub or set GH_TOKEN / GITHUB_TOKEN.")
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
    /// no duplicate in the store, and a non-empty GitHub URL.
    private var canImport: Bool {
        !detectedName.isEmpty
            && existingError == nil
            && !isDuplicate
            && !effectiveGitHubURL.isEmpty
    }

    /// Checks whether the runner name is already tracked in LocalRunnerStore's index.
    private func checkDuplicate(runnerName: String) -> Bool {
        LocalRunnerStore.shared.isTracked(runnerName: runnerName)
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
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            openPanel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = openPanel.url else { return }
                handlePickedFolder(url)
            }
        } else {
            // No key or main window available (e.g. panel not yet focused) — fall back to
            // a modal run so the picker still works instead of silently doing nothing.
            let response = openPanel.runModal()
            if response == .OK, let url = openPanel.url { handlePickedFolder(url) }
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

        /// Minimal `.runner` JSON payload — only name and GitHub URL are needed.
        struct RunnerJSON: Decodable {
            /// The URL of the GitHub repo or org this runner is registered to.
            let gitHubUrl: String?
            /// The registered runner name.
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

    /// Fetches the user's repos and organisations on a background thread.
    ///
    /// Uses a plain `Task` (not `Task.detached`) because `AddRunnerSheet` has no
    /// `@MainActor` annotation at the type level. The `Task { }` inherits the actor
    /// context of the call site (button action / `onAppear`), which is `@MainActor`,
    /// but `fetchUserRepos()` and `fetchUserOrgs()` immediately suspend to the
    /// cooperative pool via their own `await` boundaries — they do not block the
    /// main actor. The explicit `await MainActor.run { … }` at the end re-confines
    /// the UI state write to the main actor, which is correct and required.
    ///
    /// Using `Task.detached` here would achieve the same concurrency effect but
    /// force explicit re-capture of every dependency. Plain `Task` is cleaner and
    /// equally correct in this context.
    private func loadScopes() {
        isLoadingScopes = true
        Task(priority: .userInitiated) {
            let fetchedRepos = await fetchUserRepos()
            let fetchedOrgs  = await fetchUserOrgs()
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
    ///
    /// ## Actor isolation — read before changing this function
    /// `AddRunnerSheet` is a plain `struct … View` with **no** `@MainActor` annotation on the
    /// type itself. Swift only synthesises `@MainActor` isolation for a SwiftUI `View` when the
    /// conformance is on an explicitly `@MainActor`-annotated type — it does NOT do so for
    /// unannotated structs. Only `body` and helpers explicitly marked `@MainActor` (e.g.
    /// `setStep`) run on the main actor.
    ///
    /// `register()` carries **no** actor annotation. A `Task { await register() }` created from
    /// a SwiftUI button action inherits the *caller's* actor isolation only if the callee is
    /// itself actor-isolated. Because `register()` is unannotated, the Task runs on the
    /// cooperative thread pool — **not** on `@MainActor`. This is the correct and intended
    /// behaviour, not a bug.
    ///
    /// Consequences:
    /// - `FileManager` calls run synchronously on a pool thread (cheap, non-blocking — fine).
    /// - `fetchRegistrationToken` is synchronous + `DispatchSemaphore`-based and is called from
    ///   the pool, never from the main actor. The semaphore blocks a pool thread only.
    ///   Blocking a cooperative pool thread is a known limitation tracked as issue #1077
    ///   (migrate mutation helpers to async/await). It is acceptable here because runner
    ///   registration is a rare, user-initiated, one-shot action — not a hot path.
    ///   `urlSessionPost` contains `dispatchPrecondition(.notOnQueue(.main))` — this is the
    ///   runtime canary: it would trap in every debug build if we were ever accidentally on
    ///   `@MainActor`. It has never fired.
    /// - All three `await` sites (`fetchRunnerDownloadURL`, `runSimpleProcess`,
    ///   `runRegistrationCommand`) suspend the pool task, not the main actor.
    ///
    /// If `register()` is ever moved to a `@MainActor`-isolated context, `fetchRegistrationToken`
    /// **must** be migrated to `async` first — or wrapped in `Task.detached { }.value`.
    private func register() async {
        guard canRegister else { return }
        errorMessage = nil
        registrationStep = ""
        isRegistering = true
        let scope  = effectiveScope
        let name   = runnerName.trimmingCharacters(in: .whitespaces)
        let labels = labelsText.trimmingCharacters(in: .whitespaces)
        let dir    = installDir.trimmingCharacters(in: .whitespaces)
        let currentScopeType = scopeType

        let homeDir     = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let resolvedDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
            isRegistering = false
            errorMessage  = "Install directory must be inside your home folder (~/…)."
            return
        }

        let runnerFile = URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
        if FileManager.default.fileExists(atPath: runnerFile) {
            isRegistering = false
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            isRegistering = false
            errorMessage  = "Failed to create directory: \(error.localizedDescription)"
            return
        }

        let configPath = URL(fileURLWithPath: dir).appendingPathComponent("config.sh").path

        if !FileManager.default.fileExists(atPath: configPath) {
            await setStep("Downloading runner package…")
            guard let downloadURL = await fetchRunnerDownloadURL() else {
                isRegistering = false
                errorMessage  = "Could not determine runner download URL. Check your internet connection."
                return
            }
            let tarPath = URL(fileURLWithPath: dir)
                .appendingPathComponent("actions-runner.tar.gz").path
            let curlResult = await runSimpleProcess(
                GitHubURIs.curlPath,
                args: ["-sL", downloadURL, "-o", tarPath]
            )
            guard curlResult == 0 else {
                isRegistering = false
                errorMessage = "Download failed."
                return
            }
            await setStep("Unpacking runner package…")
            let tarResult = await runSimpleProcess(GitHubURIs.tarPath, args: ["xzf", tarPath, "-C", dir])
            try? FileManager.default.removeItem(atPath: tarPath)
            guard tarResult == 0 else {
                isRegistering = false
                errorMessage = "Unpack failed."
                return
            }
        }

        await setStep("Fetching registration token…")
        // fetchRegistrationToken is synchronous (DispatchSemaphore inside urlSessionPost).
        // Safe here because register() runs on the cooperative thread pool, not @MainActor —
        // see the isolation note in the doc comment above. The semaphore blocks a pool thread
        // for the network round-trip only. urlSessionPost's dispatchPrecondition(.notOnQueue(.main))
        // will trap in debug builds if this ever accidentally moves to the main actor.
        guard let token = fetchRegistrationToken(scope: scope) else {
            isRegistering = false
            if currentScopeType == .org {
                errorMessage = "Not authorised to register org-level runners. Ensure your token has the 'manage_runners:org' scope, or sign in via the GitHub button in Settings."
            } else {
                errorMessage = "Could not get a registration token. Ensure a valid token is available via OAuth sign-in, or the GH_TOKEN / GITHUB_TOKEN environment variable."
            }
            return
        }

        await setStep("Configuring runner…")
        let ghURL      = "\(GitHubURIs.base)\(scope)"
        let configExit = await runRegistrationCommand(
            dir: dir, ghURL: ghURL, token: token, name: name, labels: labels
        )
        guard configExit == 0 else {
            isRegistering = false
            errorMessage  = "config.sh failed (exit \(configExit)). Check the token is valid and the runner name is unique."
            return
        }

        await setStep("Registering service…")
        writeLaunchAgentPlist(scope: scope, runnerName: name, workingDirectory: dir)
        LocalRunnerStore.shared.add(runnerName: name, installPath: dir)
        isRegistering    = false
        registrationStep = ""
        isPresented      = false
        onComplete()
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
    ///
    /// Delegates to `ProcessRunner.runAsync` — no `nonisolated(unsafe)`, no `NSLock`,
    /// no `readabilityHandler`. Pipe drain, timeout, and cancellation are all handled
    /// by `ProcessRunner.runAsync` via its `Box + drainQueue` + `withTaskCancellationHandler`
    /// pattern (see `ProcessRunner.swift`).
    private func runRegistrationCommand(
        dir: String, ghURL: String, token: String, name: String, labels: String
    ) async -> Int32 {
        var args = ["--url", ghURL, "--token", token, "--name", name, "--unattended"]
        if !labels.isEmpty { args += ["--labels", labels] }
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: dir).appendingPathComponent("config.sh"),
            arguments: args,
            workingDirectory: URL(fileURLWithPath: dir),
            mergeStderr: true,
            timeout: 120
        )
        log("runRegistrationCommand › exit=\(result.exitCode): \(result.output.prefix(500))")
        return result.exitCode
    }

    /// Launches `executable` with `args` asynchronously and returns the termination status.
    ///
    /// Delegates to `ProcessRunner.runAsync` — no blocking `waitUntilExit()` on the
    /// cooperative thread pool. stderr is discarded (default `mergeStderr: false`).
    private func runSimpleProcess(_ executable: String, args: [String]) async -> Int32 {
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: executable),
            arguments: args,
            timeout: 120
        )
        log("runSimpleProcess › \(executable) exit \(result.exitCode)")
        return result.exitCode
    }
}

// MARK: - Runner download URL

/// Queries the GitHub API for the latest macOS runner release and returns the `.tar.gz` download URL
/// matching the current CPU architecture (`arm64` or `x64`).
///
/// Uses `URLSession.data(for:)` async/await for the API call — no blocking `Data(contentsOf:)`.
/// Architecture detection uses `ProcessRunner.runAsync` — consistent with the rest of the file
/// and avoids `waitUntilExit()` on the cooperative thread pool.
private func fetchRunnerDownloadURL() async -> String? {
    let archResult = await ProcessRunner.runAsync(
        executableURL: URL(fileURLWithPath: GitHubURIs.unamePath),
        arguments: ["-m"],
        timeout: 5
    )
    let arch      = archResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let assetArch = (arch == "arm64") ? "arm64" : "x64"
    let assetName = "actions-runner-osx-\(assetArch)"
    log("fetchRunnerDownloadURL › arch=\(arch) assetName=\(assetName)")

    guard let url = URL(string: GitHubURIs.apiRunnerLatest) else {
        log("fetchRunnerDownloadURL › invalid URL")
        return nil
    }
    let data: Data
    do {
        let (responseData, _) = try await URLSession.shared.data(from: url)
        data = responseData
    } catch {
        log("fetchRunnerDownloadURL › network error: \(error.localizedDescription)")
        return nil
    }
    /// Minimal GitHub release asset payload.
    struct Asset: Decodable {
        /// The asset file name.
        let name: String
        /// The direct download URL for this asset.
        let browserDownloadUrl: String
        /// Maps snake_case API keys to camelCase Swift properties.
        enum CodingKeys: String, CodingKey {
            /// The name coding key.
            case name
            /// The browserDownloadUrl coding key.
            case browserDownloadUrl = "browser_download_url"
        }
    }
    /// Minimal GitHub release payload — only assets are needed.
    struct Release: Decodable {
        /// The list of release assets.
        let assets: [Asset]
    }
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
