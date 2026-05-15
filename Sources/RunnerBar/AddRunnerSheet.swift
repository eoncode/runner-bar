import SwiftUI

// MARK: - AddRunnerSheet

/// Phase 3: Sheet view for onboarding a new self-hosted runner.
///
/// The user picks a scope (org or repo), names the runner, optionally sets
/// labels, and taps Confirm. The sheet fetches a registration token via the
/// GitHub API, then runs `./config.sh` in the runner install directory to
/// complete registration. On success it dismisses itself and calls `onComplete`
/// so the caller can re-scan and show the new runner.
///
/// Requires a GitHub token (`gh auth login`, GH_TOKEN, or GITHUB_TOKEN).
// swiftlint:disable:next type_body_length
struct AddRunnerSheet: View {
    /// Binding that controls sheet presentation; set to `false` to dismiss.
    @Binding var isPresented: Bool
    /// Called when registration succeeds so the caller can re-scan runners.
    let onComplete: () -> Void

    // MARK: Scope state

    /// Scope type selection for the new runner.
    enum ScopeType: String, CaseIterable, Identifiable {
        /// Register the runner under a specific repository (owner/repo).
        case repo = "Repository"
        /// Register the runner under an entire organisation.
        case org = "Organisation"
        /// Stable identifier for `ForEach`.
        var id: String { rawValue }
    }

    @State private var scopeType: ScopeType = .repo
    @State private var selectedRepo = ""
    @State private var selectedOrg = ""
    @State private var repos: [String] = []
    @State private var orgs: [String] = []
    @State private var isLoadingScopes = false

    // MARK: Runner config state

    @State private var runnerName = ""
    @State private var labelsText = "self-hosted,macOS"
    @State private var installDir = (FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("actions-runner").path)

    // MARK: Registration state

    @State private var isRegistering = false
    @State private var errorMessage: String?

    // MARK: - Body

    /// The sheet's root view.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add runner")
                .font(.headline)

            Picker("Scope", selection: $scopeType) {
                ForEach(ScopeType.allCases) { scopeOption in
                    Text(scopeOption.rawValue).tag(scopeOption)
                }
            }
            .pickerStyle(.segmented)

            if isLoadingScopes {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading\u{2026}").font(.caption).foregroundColor(.secondary)
                }
            } else if scopeType == .repo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $selectedRepo) {
                        Text("\u{2014} select \u{2014}").tag("")
                        ForEach(repos, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    if repos.isEmpty {
                        Text("No repositories found. Run `gh auth login` or set GH_TOKEN.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organisation").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $selectedOrg) {
                        Text("\u{2014} select \u{2014}").tag("")
                        ForEach(orgs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    if orgs.isEmpty {
                        Text("No organisations found. Run `gh auth login` or set GH_TOKEN.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Runner name").font(.caption).foregroundColor(.secondary)
                TextField("e.g. my-mac-runner", text: $runnerName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Labels (comma-separated)").font(.caption).foregroundColor(.secondary)
                TextField("e.g. self-hosted,macOS,arm64", text: $labelsText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Runner install directory").font(.caption).foregroundColor(.secondary)
                TextField("", text: $installDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
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
                Button(action: { isPresented = false }, label: { Text("Cancel") })
                    .keyboardShortcut(.cancelAction)
                Button(
                    action: register,
                    label: {
                        if isRegistering {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("Registering\u{2026}")
                            }
                        } else {
                            Text("Add Runner")
                        }
                    }
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!canRegister || isRegistering)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear(perform: loadScopes)
    }

    // MARK: - Helpers

    /// The effective scope string (repo or org) for registration.
    private var effectiveScope: String {
        scopeType == .repo ? selectedRepo : selectedOrg
    }

    /// `true` when the form has enough data to attempt registration.
    private var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !effectiveScope.isEmpty
    }

    /// Fetches available repos and orgs in the background.
    private func loadScopes() {
        isLoadingScopes = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedRepos = fetchUserRepos()
            let fetchedOrgs = fetchUserOrgs()
            DispatchQueue.main.async {
                repos = fetchedRepos
                orgs = fetchedOrgs
                if let first = fetchedRepos.first { selectedRepo = first }
                if let firstOrg = fetchedOrgs.first { selectedOrg = firstOrg }
                isLoadingScopes = false
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private func register() {
        guard canRegister else { return }
        errorMessage = nil
        isRegistering = true
        let scope = effectiveScope
        let name = runnerName.trimmingCharacters(in: .whitespaces)
        let labels = labelsText.trimmingCharacters(in: .whitespaces)
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
                .resolvingSymlinksInPath().path
            let resolvedDir = URL(fileURLWithPath: dir)
                .resolvingSymlinksInPath().path
            // ⚠️ SECURITY: use `homeDir + "/"` as the prefix, NOT bare `homeDir`.
            // Checking `hasPrefix(homeDir)` alone would allow a path like
            // `/Users/alice-evil` to match against a home dir of `/Users/alice`,
            // enabling a directory-traversal attack. The trailing slash ensures
            // the match is a true path prefix (a child directory), not just a
            // string prefix of the home path.
            // ❌ NEVER simplify this to `hasPrefix(homeDir)` — it is a security bug.
            guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage = "Install directory must be inside your home folder (~/\u{2026})."
                }
                return
            }
            guard let token = fetchRegistrationToken(scope: scope) else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage = "Failed to fetch registration token. " +
                        "Ensure `gh auth login` has been run or GH_TOKEN is set."
                }
                return
            }
            do {
                try FileManager.default.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true
                )
            } catch {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage = "Failed to create directory: \(error.localizedDescription)"
                }
                return
            }
            let ghURL = "https://github.com/\(scope)"
            let exitCode = runRegistrationCommand(
                dir: dir,
                ghURL: ghURL,
                token: token,
                name: name,
                labels: labels
            )
            DispatchQueue.main.async {
                isRegistering = false
                if exitCode == 0 {
                    isPresented = false
                    onComplete()
                } else {
                    errorMessage = "config.sh failed (exit \(exitCode)). " +
                        "Check that the token is valid and config.sh is executable."
                }
            }
        }
    }

    /// Runs `config.sh` via `Process.arguments`; returns the exit code.
    private func runRegistrationCommand(
        dir: String,
        ghURL: String,
        token: String,
        name: String,
        labels: String
    ) -> Int32 {
        let configURL = URL(fileURLWithPath: dir).appendingPathComponent("config.sh")
        let task = Process()
        task.executableURL = configURL
        task.currentDirectoryURL = URL(fileURLWithPath: dir)
        var args = ["--url", ghURL, "--token", token, "--name", name, "--unattended"]
        if !labels.isEmpty { args += ["--labels", labels] }
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        var outputData = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            outputData.append(chunk)
            lock.unlock()
        }
        do { try task.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("runRegistrationCommand \u{203A} launch error: \(error)")
            return 1
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty {
            lock.lock()
            outputData.append(tail)
            lock.unlock()
        }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        log("runRegistrationCommand \u{203A} exit=\(task.terminationStatus): \(output.prefix(120))")
        return task.terminationStatus
    }
}
