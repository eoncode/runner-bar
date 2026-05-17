import SwiftUI

// swiftlint:disable type_body_length
// MARK: - AddRunnerSheet

/// Phase 3: Sheet view for onboarding a new self-hosted runner.
///
/// The user picks a scope (org or repo), names the runner, optionally sets
/// labels, and taps Confirm. The sheet fetches a registration token via the
/// GitHub API, downloads the runner tarball, unpacks it, then runs `./config.sh`
/// in the runner install directory to complete registration. On success it
/// dismisses itself and calls `onComplete` so the caller can re-scan and show
/// the new runner.
///
/// Requires a GitHub token (`gh auth login`, GH_TOKEN, or GITHUB_TOKEN).
struct AddRunnerSheet: View {
    /// Binding that controls sheet presentation; set to `false` to dismiss.
    @Binding var isPresented: Bool
    /// Called when registration succeeds so the caller can re-scan runners.
    let onComplete: () -> Void

    // MARK: Scope state

    /// Scope type selection for the new runner: a specific repository or an organisation.
    enum ScopeType: String, CaseIterable, Identifiable {
        /// Register the runner under a specific repository (owner/repo).
        case repo = "Repository"
        /// Register the runner under an entire organisation.
        case org = "Organisation"
        /// Stable identifier for `ForEach` — uses the raw string value.
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
    @State private var registrationStep = ""
    @State private var errorMessage: String?

    // MARK: - Body

    /// The sheet's root view: scope picker, runner name/labels/dir fields, and Add/Cancel buttons.
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
                    Text("Loading…").font(.caption).foregroundColor(.secondary)
                }
            } else if scopeType == .repo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repository").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $selectedRepo) {
                        Text("— select —").tag("")
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
                        Text("— select —").tag("")
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

            if isRegistering && !registrationStep.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(registrationStep)
                        .font(.caption).foregroundColor(.secondary)
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
                Button(action: { isPresented = false }, label: { Text("Cancel") })
                    .keyboardShortcut(.cancelAction)
                Button(action: register, label: {
                    if isRegistering {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Registering…")
                        }
                    } else {
                        Text("Add Runner")
                    }
                })
                .keyboardShortcut(.defaultAction)
                .disabled(!canRegister || isRegistering)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear(perform: loadScopes)
    }

    // MARK: - Helpers

    private var effectiveScope: String {
        scopeType == .repo ? selectedRepo : selectedOrg
    }

    private var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty
            && !effectiveScope.isEmpty
    }

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

    private func setStep(_ msg: String) {
        DispatchQueue.main.async { registrationStep = msg }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func register() {
        guard canRegister else { return }
        errorMessage = nil
        registrationStep = ""
        isRegistering = true
        let scope = effectiveScope
        let name = runnerName.trimmingCharacters(in: .whitespaces)
        let labels = labelsText.trimmingCharacters(in: .whitespaces)
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            // Security: validate that installDir resolves to a path inside the
            // user's home directory before executing config.sh there.
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
                .resolvingSymlinksInPath().path
            let resolvedDir = URL(fileURLWithPath: dir)
                .resolvingSymlinksInPath().path
            guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage = "Install directory must be inside your home folder (~/…)."
                }
                return
            }

            // Step 1: Fetch registration token.
            setStep("Fetching registration token…")
            guard let token = fetchRegistrationToken(scope: scope) else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage = "Failed to fetch registration token. " +
                        "Ensure `gh auth login` has been run or GH_TOKEN is set."
                }
                return
            }

            // Step 2: Create install directory.
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

            // Step 3: Download runner tarball if config.sh is not already present.
            let configURL = URL(fileURLWithPath: dir).appendingPathComponent("config.sh")
            if !FileManager.default.fileExists(atPath: configURL.path) {
                setStep("Downloading runner package…")
                guard let downloadURL = fetchRunnerDownloadURL() else {
                    DispatchQueue.main.async {
                        isRegistering = false
                        errorMessage = "Could not determine runner download URL. " +
                            "Check your internet connection."
                    }
                    return
                }
                let tarPath = URL(fileURLWithPath: dir).appendingPathComponent("actions-runner.tar.gz").path
                let dlExit = runSimpleProcess("/usr/bin/curl", args: ["-sL", downloadURL, "-o", tarPath])
                guard dlExit == 0 else {
                    DispatchQueue.main.async {
                        isRegistering = false
                        errorMessage = "Download failed (exit \(dlExit))."
                    }
                    return
                }

                // Step 4: Unpack tarball.
                setStep("Unpacking runner package…")
                let tarExit = runSimpleProcess("/usr/bin/tar", args: ["xzf", tarPath, "-C", dir])
                // Remove tarball regardless of outcome.
                try? FileManager.default.removeItem(atPath: tarPath)
                guard tarExit == 0 else {
                    DispatchQueue.main.async {
                        isRegistering = false
                        errorMessage = "Unpack failed (exit \(tarExit))."
                    }
                    return
                }
            }

            // Step 5: Run config.sh.
            setStep("Configuring runner…")
            let ghURL = scopeType == .repo
                ? "https://github.com/\(scope)"
                : "https://github.com/\(scope)"
            let exitCode = runRegistrationCommand(dir: dir, ghURL: ghURL,
                                                  token: token, name: name, labels: labels)
            DispatchQueue.main.async {
                isRegistering = false
                registrationStep = ""
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

    /// Runs `config.sh` via `Process.arguments` so token/name/url are never
    /// shell-interpolated. Arguments are passed as discrete array entries.
    ///
    /// ⚠️ Blocking — must only be called from a background thread.
    ///
    /// Returns the process exit code (0 = success).
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
            lock.lock(); outputData.append(chunk); lock.unlock()
        }
        do { try task.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("runRegistrationCommand › launch error: \(error)")
            return 1
        }
        let timeoutItem = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutItem)
        task.waitUntilExit()
        timeoutItem.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        if !tail.isEmpty { lock.lock(); outputData.append(tail); lock.unlock() }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        log("runRegistrationCommand › exit=\(task.terminationStatus): \(output.prefix(120))")
        return task.terminationStatus
    }

    /// Runs a simple process synchronously and returns its exit code.
    /// Blocking — call only from a background thread.
    private func runSimpleProcess(_ executable: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
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

/// Fetches the macOS runner tarball download URL for the current architecture
/// from the latest GitHub Actions runner release.
///
/// Uses `uname -m` to detect `arm64` vs `x86_64` and selects the matching asset.
/// Returns `nil` if the release API is unreachable or no matching asset is found.
private func fetchRunnerDownloadURL() -> String? {
    // Detect host architecture.
    let archTask = Process()
    archTask.executableURL = URL(fileURLWithPath: "/usr/bin/uname")
    archTask.arguments = ["-m"]
    let archPipe = Pipe()
    archTask.standardOutput = archPipe
    archTask.standardError = Pipe()
    guard (try? archTask.run()) != nil else { return nil }
    archTask.waitUntilExit()
    let archData = archPipe.fileHandleForReading.readDataToEndOfFile()
    let arch = String(data: archData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // Map uname output to GitHub asset name fragment.
    let assetArch = (arch == "arm64") ? "arm64" : "x64"
    let assetName = "actions-runner-osx-\(assetArch)"
    log("fetchRunnerDownloadURL › arch=\(arch) assetName=\(assetName)")

    // Fetch latest release from GitHub API (no auth needed for public repo).
    guard let url = URL(string: "https://api.github.com/repos/actions/runner/releases/latest"),
          let data = try? Data(contentsOf: url) else {
        log("fetchRunnerDownloadURL › failed to fetch release JSON")
        return nil
    }
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
    struct Release: Decodable { let assets: [Asset] }
    guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
        log("fetchRunnerDownloadURL › decode failed")
        return nil
    }
    let match = release.assets.first(where: {
        $0.name.hasPrefix(assetName) && $0.name.hasSuffix(".tar.gz")
    })
    log("fetchRunnerDownloadURL › match=\(match?.name ?? "nil")")
    return match?.browserDownloadUrl
}
// swiftlint:enable type_body_length
