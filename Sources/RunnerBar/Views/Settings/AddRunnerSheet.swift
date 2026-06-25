// AddRunnerSheet.swift
// RunnerBar
import AppKit
import SwiftUI

// MARK: - URI Constants

/// Centralised URI and path constants used by `AddRunnerSheet` and its extensions.
enum GitHubURIs {
    static let base = "https://github.com/" // NOSONAR
    static let apiRunnerLatest = "https://api.github.com/repos/actions/runner/releases/latest" // NOSONAR
    static let launchAgentsDir = "Library/LaunchAgents"
    static let actionsRunnerDefaultDir = "actions-runner/my-runner"
    static let curlPath = "/usr/bin/curl" // NOSONAR
    static let tarPath = "/usr/bin/tar"  // NOSONAR
    static let unamePath = "/usr/bin/uname" // NOSONAR
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
/// ## Visibility note
/// All `@State` properties and extension-facing helpers are `internal` (no modifier)
/// rather than `private` because Swift does not allow `private` members of a primary
/// type to be accessed from extensions defined in separate files.
struct AddRunnerSheet: View {
    /// Controls whether the sheet is shown.
    @Binding var isPresented: Bool
    /// Called when registration or import completes successfully.
    let onComplete: () -> Void
    /// Injected local runner store — avoids direct `.shared` references inside the sheet.
    var localRunnerStore: LocalRunnerStore = .shared
    /// Core runner state — read for synchronous duplicate checks against localRunners.
    @Environment(RunnerState.self) var runnerState: RunnerState

    // MARK: - Add Mode

    enum AddMode: String, CaseIterable, Identifiable {
        case addNew = "Add new"
        case addExisting = "Add pre-existing"
        var id: String { rawValue }
    }

    @State var addMode: AddMode = .addNew

    // MARK: - Internal state (extension-accessible)

    // MARK: Scope state (Add new only)
    enum ScopeType: String, CaseIterable, Identifiable {
        case repo = "Repository"
        case org = "Organisation"
        var id: String { rawValue }
    }

    @State var scopeType: ScopeType = .repo
    @State var selectedRepo = ""
    @State var selectedOrg = ""
    @State var repos: [String] = []
    @State var orgs: [String] = []
    @State var isLoadingScopes = false
    @State var showRepoSelector = false
    @State var showOrgSelector = false

    // MARK: Runner config state (Add new only)
    @State var runnerName = ""
    @State var labelsText = "self-hosted,macOS"
    @State var installDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path

    // MARK: Registration state (Add new only)
    @State var isRegistering = false
    @State var registrationStep = ""
    @State var errorMessage: String?

    // MARK: Pre-existing state (Add pre-existing only)
    @State var existingDir = ""
    @State var detectedName = ""
    @State var detectedGitHubURL = ""
    @State var existingError: String?
    @State var githubURLOverride = ""
    @State var isDuplicate = false
    @State var hostWindow: NSWindow?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add runner").font(.headline)

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

            if addMode == .addNew {
                addNewFormBody
            } else {
                addExistingFormBody
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(WindowGrabber { w in
            if hostWindow == nil, let w { hostWindow = w }
        })
        .onAppear {
            if addMode == .addNew { loadScopes() }
        }
    }

    // MARK: - State reset helpers

    func resetAddNewState() {
        runnerName = ""
        labelsText = "self-hosted,macOS"
        installDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(GitHubURIs.actionsRunnerDefaultDir).path
        isRegistering = false
        registrationStep = ""
        errorMessage = nil
        scopeType = .repo
        selectedRepo = repos.first ?? ""
        selectedOrg = orgs.first ?? ""
        if addMode == .addNew && repos.isEmpty && orgs.isEmpty {
            loadScopes()
        }
    }

    func resetExistingState() {
        existingDir = ""
        detectedName = ""
        detectedGitHubURL = ""
        existingError = nil
        githubURLOverride = ""
        isDuplicate = false
    }

    // MARK: - Plist writer (shared by both modes)

    nonisolated func writeLaunchAgentPlist(scope: String, runnerName: String, workingDirectory: String) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(GitHubURIs.launchAgentsDir)
        let scopeParts = scope.components(separatedBy: "/")
        let owner = scopeParts[0]
        let repo = scopeParts.count > 1 ? scopeParts[1] : scopeParts[0]
        let label = "actions.runner.\(owner).\(repo).\(runnerName)"
        let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")

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

    func runRegistrationCommand(
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

    func runSimpleProcess(_ executable: String, args: [String]) async -> Int32 {
        let result = await ProcessRunner.runAsync(
            executableURL: URL(fileURLWithPath: executable),
            arguments: args,
            timeout: 120
        )
        log("runSimpleProcess › \(executable) exit \(result.exitCode)")
        return result.exitCode
    }

    // MARK: - Register (Add new)

    func register() async {
        guard canRegister else { return }
        errorMessage = nil
        registrationStep = ""
        isRegistering = true
        let scope = effectiveScope
        let name = runnerName.trimmingCharacters(in: .whitespaces)
        let labels = labelsText.trimmingCharacters(in: .whitespaces)
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        let currentScopeType = scopeType

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let resolvedDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
            isRegistering = false
            errorMessage = "Install directory must be inside your home folder (~/\u{2026})."
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
            errorMessage = "Failed to create directory: \(error.localizedDescription)"
            return
        }

        let configPath = URL(fileURLWithPath: dir).appendingPathComponent("config.sh").path

        if !FileManager.default.fileExists(atPath: configPath) {
            setStep("Downloading runner package\u{2026}")
            guard let downloadURL = await fetchRunnerDownloadURL() else {
                isRegistering = false
                errorMessage = "Could not determine runner download URL. Check your internet connection."
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
            setStep("Unpacking runner package\u{2026}")
            let tarResult = await runSimpleProcess(GitHubURIs.tarPath, args: ["xzf", tarPath, "-C", dir])
            try? FileManager.default.removeItem(atPath: tarPath)
            guard tarResult == 0 else {
                isRegistering = false
                errorMessage = "Unpack failed."
                return
            }
        }

        setStep("Fetching registration token\u{2026}")
        guard let token = await fetchRegistrationToken(scope: scope) else {
            isRegistering = false
            if currentScopeType == .org {
                errorMessage = "Not authorised to register org-level runners. Ensure your token has the 'manage_runners:org' scope, or sign in via the GitHub button in Settings."
            } else {
                errorMessage = "Could not get a registration token. Ensure a valid token is available via OAuth sign-in, or the GH_TOKEN / GITHUB_TOKEN environment variable."
            }
            return
        }

        setStep("Configuring runner\u{2026}")
        let ghURL = "\(GitHubURIs.base)\(scope)"
        let configExit = await runRegistrationCommand(
            dir: dir, ghURL: ghURL, token: token, name: name, labels: labels
        )
        guard configExit == 0 else {
            isRegistering = false
            errorMessage = "config.sh failed (exit \(configExit)). Check the token is valid and the runner name is unique."
            return
        }

        setStep("Registering service\u{2026}")
        writeLaunchAgentPlist(scope: scope, runnerName: name, workingDirectory: dir)
        await localRunnerStore.add(runnerName: name, installPath: dir)
        isRegistering = false
        registrationStep = ""
        isPresented = false
        onComplete()
    }
}
