import SwiftUI

// swiftlint:disable type_body_length
// MARK: - AddRunnerSheet

/// Sheet view for onboarding a self-hosted runner.
///
/// Supports two modes selectable via a segmented control at the top:
///
/// - **Add new**: downloads, configures and registers a brand-new runner with GitHub.
/// - **Add pre-existing**: imports a runner folder that was already configured outside
///   of RunnerBar (e.g. via terminal). Only writes the LaunchAgent plist so
///   `LocalRunnerScanner` can discover the runner — no token or download needed.
///
/// After successful registration/import the app writes a minimal LaunchAgent plist to
/// `~/Library/LaunchAgents/actions.runner.<owner>.<repo>.<name>.plist` directly
/// via FileManager. This avoids calling `svc.sh install` (which requires an
/// interactive user session and fails from an app-launched Process) while still
/// giving `LocalRunnerScanner` the `WorkingDirectory` key it needs to find the
/// runner on every subsequent scan — including after a full app reinstall.
///
/// Requires a GitHub token for "Add new" only (`gh auth login`, GH_TOKEN, or GITHUB_TOKEN).
struct AddRunnerSheet: View {
    @Binding var isPresented: Bool
    let onComplete: () -> Void

    // MARK: - Add Mode

    /// Controls which form body is shown in the sheet.
    enum AddMode: String, CaseIterable, Identifiable {
        case addNew      = "Add new"
        case addExisting = "Add pre-existing"
        var id: String { rawValue }
    }

    @State private var addMode: AddMode = .addNew

    // MARK: Scope state (Add new only)

    enum ScopeType: String, CaseIterable, Identifiable {
        case repo = "Repository"
        case org  = "Organisation"
        var id: String { rawValue }
    }

    @State private var scopeType: ScopeType = .repo
    @State private var selectedRepo = ""
    @State private var selectedOrg  = ""
    @State private var repos: [String] = []
    @State private var orgs:  [String] = []
    @State private var isLoadingScopes = false

    // MARK: Runner config state (Add new only)

    @State private var runnerName = ""
    @State private var labelsText = "self-hosted,macOS"
    /// Default: ~/actions-runner/my-runner — user should rename the last
    /// component to match their runner name. Each runner needs its own folder.
    @State private var installDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("actions-runner/my-runner").path

    // MARK: Registration state (Add new only)

    @State private var isRegistering    = false
    @State private var registrationStep = ""
    @State private var errorMessage: String?

    // MARK: - Body

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
            .onChange(of: addMode) { _ in resetAddNewState() }

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

    @ViewBuilder
    private var addNewFormBody: some View {
        // Scope picker
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
            scopePicker(
                label: "Repository",
                selection: $selectedRepo,
                items: repos,
                empty: "No repositories found. Run `gh auth login` or set GH_TOKEN."
            )
        } else {
            scopePicker(
                label: "Organisation",
                selection: $selectedOrg,
                items: orgs,
                empty: "No organisations found. Run `gh auth login` or set GH_TOKEN."
            )
        }

        labeledField("Runner name", placeholder: "e.g. my-mac-runner", text: $runnerName)
        labeledField(
            "Labels (comma-separated)",
            placeholder: "e.g. self-hosted,macOS,arm64",
            text: $labelsText
        )

        // Install directory field
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
            Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            Button(action: register) {
                if isRegistering {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
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

    // MARK: - Add Pre-Existing Form Body (Phase 2 placeholder)

    @ViewBuilder
    private var addExistingFormBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a folder that already contains a configured runner.")
                .font(.caption)
                .foregroundColor(.secondary)

            // TODO: Phase 2 — folder picker + .runner JSON detection
            // TODO: Phase 3 — import action + plist write + duplicate validation
            Text("Coming soon")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func scopePicker(label: String, selection: Binding<String>,
                             items: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Picker("", selection: selection) {
                Text("— select —").tag("")
                ForEach(items, id: \.self) { Text($0).tag($0) }
            }.labelsHidden()
            if items.isEmpty { Text(empty).font(.caption2).foregroundColor(.secondary) }
        }
    }

    @ViewBuilder
    private func labeledField(_ title: String, placeholder: String,
                              text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Helpers

    private var effectiveScope: String { scopeType == .repo ? selectedRepo : selectedOrg }

    private var dirAlreadyConfigured: Bool {
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
        )
    }

    private var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !effectiveScope.isEmpty
            && !dirAlreadyConfigured
    }

    /// Resets all "Add new" form state. Called when switching away from .addNew mode.
    private func resetAddNewState() {
        runnerName       = ""
        labelsText       = "self-hosted,macOS"
        installDir       = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("actions-runner/my-runner").path
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

    private func loadScopes() {
        isLoadingScopes = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedRepos = fetchUserRepos()
            let fetchedOrgs  = fetchUserOrgs()
            DispatchQueue.main.async {
                repos = fetchedRepos
                orgs  = fetchedOrgs
                if let first = fetchedRepos.first { selectedRepo = first }
                if let first = fetchedOrgs.first  { selectedOrg  = first }
                isLoadingScopes = false
            }
        }
    }

    private func setStep(_ msg: String) {
        DispatchQueue.main.async { registrationStep = msg }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func register() {
        guard canRegister else { return }
        errorMessage = nil
        registrationStep = ""
        isRegistering = true
        let scope  = effectiveScope
        let name   = runnerName.trimmingCharacters(in: .whitespaces)
        let labels = labelsText.trimmingCharacters(in: .whitespaces)
        let dir    = installDir.trimmingCharacters(in: .whitespaces)

        DispatchQueue.global(qos: .userInitiated).async {
            // Security: only allow paths inside the user's home directory.
            let homeDir     = FileManager.default.homeDirectoryForCurrentUser
                .resolvingSymlinksInPath().path
            let resolvedDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage  = "Install directory must be inside your home folder (~/…)."
                }
                return
            }

            let runnerFile = URL(fileURLWithPath: dir).appendingPathComponent(".runner").path
            if FileManager.default.fileExists(atPath: runnerFile) {
                DispatchQueue.main.async { isRegistering = false }
                return
            }

            // 1. Create install directory.
            do {
                try FileManager.default.createDirectory(atPath: dir,
                                                        withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage  = "Failed to create directory: \(error.localizedDescription)"
                }
                return
            }

            let configPath = URL(fileURLWithPath: dir).appendingPathComponent("config.sh").path

            // 2. Download + unpack runner package if config.sh is absent.
            if !FileManager.default.fileExists(atPath: configPath) {
                setStep("Downloading runner package…")
                guard let downloadURL = fetchRunnerDownloadURL() else {
                    DispatchQueue.main.async {
                        isRegistering = false
                        errorMessage  = "Could not determine runner download URL. Check your internet connection."
                    }
                    return
                }
                let tarPath = URL(fileURLWithPath: dir)
                    .appendingPathComponent("actions-runner.tar.gz").path
                guard runSimpleProcess("/usr/bin/curl",
                                      args: ["-sL", downloadURL, "-o", tarPath]) == 0 else {
                    DispatchQueue.main.async { isRegistering = false; errorMessage = "Download failed." }
                    return
                }
                setStep("Unpacking runner package…")
                let tarExit = runSimpleProcess("/usr/bin/tar", args: ["xzf", tarPath, "-C", dir])
                try? FileManager.default.removeItem(atPath: tarPath)
                guard tarExit == 0 else {
                    DispatchQueue.main.async { isRegistering = false; errorMessage = "Unpack failed." }
                    return
                }
            }

            // 3. Fetch registration token.
            setStep("Fetching registration token…")
            guard let token = fetchRegistrationToken(scope: scope) else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage  = "Failed to fetch registration token. Ensure `gh auth login` has been run or GH_TOKEN is set."
                }
                return
            }

            // 4. Run config.sh to register the runner with GitHub.
            setStep("Configuring runner…")
            let ghURL      = "https://github.com/\(scope)"
            let configExit = runRegistrationCommand(dir: dir, ghURL: ghURL,
                                                    token: token, name: name, labels: labels)
            guard configExit == 0 else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage  = "config.sh failed (exit \(configExit)). Check the token is valid and the runner name is unique."
                }
                return
            }

            // 5. Write a minimal LaunchAgent plist so LocalRunnerScanner can find
            //    this runner on every future scan via the WorkingDirectory key.
            //
            //    We write the plist directly with FileManager rather than calling
            //    `svc.sh install` because svc.sh requires an interactive user
            //    session (`launchctl bootstrap`) and exits 1 when invoked from an
            //    app-launched Process. Writing the plist ourselves achieves the
            //    same result with no elevated permissions.
            //
            //    The plist is intentionally minimal: it stores WorkingDirectory so
            //    the scanner resolves the install path, but does NOT set RunAtLoad
            //    or ProgramArguments — the user can enable auto-start separately
            //    via the lifecycle controls (Phase 2).
            setStep("Registering service…")
            writeLaunchAgentPlist(scope: scope, runnerName: name, workingDirectory: dir)

            DispatchQueue.main.async {
                isRegistering    = false
                registrationStep = ""
                isPresented      = false
                onComplete()
            }
        }
    }

    /// Writes a minimal LaunchAgent plist to `~/Library/LaunchAgents/`.
    /// The plist contains the `WorkingDirectory` key so `LocalRunnerScanner`
    /// can locate the runner on every scan without any UserDefaults persistence.
    ///
    /// Plist filename format: `actions.runner.<owner>.<repo>.<runnerName>.plist`
    /// For org-scoped runners `repo` is the org name (same component, single part).
    func writeLaunchAgentPlist(scope: String, runnerName: String, workingDirectory: String) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        // Normalise scope into owner + repo components for the filename.
        // scope is "owner/repo" (repo-scoped) or "orgname" (org-scoped).
        let scopeParts   = scope.components(separatedBy: "/")
        let owner        = scopeParts[0]
        let repo         = scopeParts.count > 1 ? scopeParts[1] : scopeParts[0]
        let label        = "actions.runner.\(owner).\(repo).\(runnerName)"
        let plistURL     = launchAgentsDir.appendingPathComponent("\(label).plist")

        let plist: NSDictionary = [
            "Label": label,
            "WorkingDirectory": workingDirectory,
        ]
        do {
            try FileManager.default.createDirectory(
                at: launchAgentsDir, withIntermediateDirectories: true)
            plist.write(to: plistURL, atomically: true)
            log("AddRunnerSheet › wrote LaunchAgent plist: \(plistURL.path)")
        } catch {
            // Non-fatal: runner is registered with GitHub; it just won't appear
            // in the scanner until the install dir falls inside a default root.
            log("AddRunnerSheet › failed to write LaunchAgent plist: \(error)")
        }
    }

    /// Runs `./config.sh --url … --token … --name … --unattended`.
    /// Timeout: 120 s. Blocking — call only from a background thread.
    private func runRegistrationCommand(
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
        var outputData = Data()
        let lock = NSLock()
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

    /// Runs a simple process synchronously. Blocking — call only from a background thread.
    private func runSimpleProcess(_ executable: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL  = URL(fileURLWithPath: executable)
        task.arguments      = args
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        do { try task.run() } catch {
            log("runSimpleProcess › \(executable) launch error: \(error)")
            return 1
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        log("runSimpleProcess › \(executable) exit \(task.terminationStatus)")
        return task.terminationStatus
    }
}

// MARK: - Runner download URL

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

    guard let url  = URL(string: "https://api.github.com/repos/actions/runner/releases/latest"),
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
