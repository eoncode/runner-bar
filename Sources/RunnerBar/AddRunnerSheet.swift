import SwiftUI

// swiftlint:disable type_body_length
// MARK: - AddRunnerSheet

/// Phase 3: Sheet view for onboarding a new self-hosted runner.
///
/// The user picks a scope (org or repo), names the runner, optionally sets
/// labels, and taps Confirm. The sheet fetches a registration token via the
/// GitHub API, downloads the runner tarball if not present, unpacks it, then
/// runs `./config.sh` in the runner install directory to complete registration.
/// On success it dismisses itself and calls `onComplete` so the caller can
/// re-scan and show the new runner.
///
/// Requires a GitHub token (`gh auth login`, GH_TOKEN, or GITHUB_TOKEN).
struct AddRunnerSheet: View {
    /// Binding that controls sheet presentation; set to `false` to dismiss.
    @Binding var isPresented: Bool
    /// Called when registration succeeds so the caller can re-scan runners.
    let onComplete: () -> Void

    // MARK: Scope state

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

    // MARK: Runner config state

    @State private var runnerName  = ""
    @State private var labelsText  = "self-hosted,macOS"
    @State private var installDir  = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("actions-runner").path

    // MARK: Registration state

    @State private var isRegistering   = false
    @State private var registrationStep = ""
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add runner").font(.headline)

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
                scopePicker(label: "Repository", selection: $selectedRepo, items: repos,
                            empty: "No repositories found. Run `gh auth login` or set GH_TOKEN.")
            } else {
                scopePicker(label: "Organisation", selection: $selectedOrg, items: orgs,
                            empty: "No organisations found. Run `gh auth login` or set GH_TOKEN.")
            }

            labeledField("Runner name", placeholder: "e.g. my-mac-runner", text: $runnerName)
            labeledField("Labels (comma-separated)", placeholder: "e.g. self-hosted,macOS,arm64", text: $labelsText)

            VStack(alignment: .leading, spacing: 4) {
                Text("Runner install directory").font(.caption).foregroundColor(.secondary)
                TextField("", text: $installDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
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
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text("Registering…") }
                    } else {
                        Text("Add Runner")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRegister || isRegistering)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear(perform: loadScopes)
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

    private var canRegister: Bool {
        !runnerName.trimmingCharacters(in: .whitespaces).isEmpty && !effectiveScope.isEmpty
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
            let homeDir     = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
            let resolvedDir = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            guard resolvedDir == homeDir || resolvedDir.hasPrefix(homeDir + "/") else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage  = "Install directory must be inside your home folder (~/…)."
                }
                return
            }

            // 1. Fetch registration token.
            setStep("Fetching registration token…")
            guard let token = fetchRegistrationToken(scope: scope) else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage  = "Failed to fetch registration token. " +
                        "Ensure `gh auth login` has been run or GH_TOKEN is set."
                }
                return
            }

            // 2. Create install directory.
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage  = "Failed to create directory: \(error.localizedDescription)"
                }
                return
            }

            // 3. Download + unpack runner package if config.sh is absent.
            let configPath = URL(fileURLWithPath: dir).appendingPathComponent("config.sh").path
            if !FileManager.default.fileExists(atPath: configPath) {
                setStep("Downloading runner package…")
                guard let downloadURL = fetchRunnerDownloadURL() else {
                    DispatchQueue.main.async {
                        isRegistering = false
                        errorMessage  = "Could not determine runner download URL. Check your internet connection."
                    }
                    return
                }
                let tarPath = URL(fileURLWithPath: dir).appendingPathComponent("actions-runner.tar.gz").path
                guard runSimpleProcess("/usr/bin/curl", args: ["-sL", downloadURL, "-o", tarPath]) == 0 else {
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

            // 4. Run config.sh.
            // --replace: removes any existing .runner registration so re-registering
            //            the same directory (or re-running after a failed attempt) works.
            // --unattended: no interactive prompts.
            setStep("Configuring runner…")
            let ghURL    = "https://github.com/\(scope)"
            let exitCode = runRegistrationCommand(dir: dir, ghURL: ghURL,
                                                  token: token, name: name, labels: labels)
            DispatchQueue.main.async {
                isRegistering   = false
                registrationStep = ""
                if exitCode == 0 {
                    isPresented = false
                    onComplete()
                } else {
                    errorMessage = "config.sh failed (exit \(exitCode)). " +
                        "Check the token is valid and the runner name is unique."
                }
            }
        }
    }

    /// Runs `config.sh --replace --unattended` so:
    ///   - `--replace` removes any pre-existing `.runner` file, allowing re-registration
    ///     of a directory that was previously configured (fixes the exit-1 on re-use).
    ///   - `--unattended` suppresses all interactive prompts.
    /// Timeout raised to 120 s — org-runner config calls back to GitHub and can be slow.
    /// ⚠️ Blocking — call only from a background thread.
    private func runRegistrationCommand(
        dir: String, ghURL: String, token: String, name: String, labels: String
    ) -> Int32 {
        let configURL = URL(fileURLWithPath: dir).appendingPathComponent("config.sh")
        let task = Process()
        task.executableURL  = configURL
        task.currentDirectoryURL = URL(fileURLWithPath: dir)
        var args = ["--url", ghURL, "--token", token, "--name", name,
                    "--unattended", "--replace"]
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
        let output = String(data: outputData, encoding: .utf8) ?? ""
        // Log up to 500 chars so failures are diagnosable without truncating key error lines.
        log("runRegistrationCommand › exit=\(task.terminationStatus): \(output.prefix(500))")
        return task.terminationStatus
    }

    /// Runs a simple process synchronously and returns its exit code.
    /// Blocking — call only from a background thread.
    private func runSimpleProcess(_ executable: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments     = args
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

/// Fetches the macOS runner tarball download URL for the current architecture
/// from the latest GitHub Actions runner release.
private func fetchRunnerDownloadURL() -> String? {
    let archTask = Process()
    archTask.executableURL = URL(fileURLWithPath: "/usr/bin/uname")
    archTask.arguments = ["-m"]
    let archPipe = Pipe()
    archTask.standardOutput = archPipe
    archTask.standardError  = Pipe()
    guard (try? archTask.run()) != nil else { return nil }
    archTask.waitUntilExit()
    let archRaw  = archPipe.fileHandleForReading.readDataToEndOfFile()
    let arch     = String(data: archRaw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let assetArch = (arch == "arm64") ? "arm64" : "x64"
    let assetName = "actions-runner-osx-\(assetArch)"
    log("fetchRunnerDownloadURL › arch=\(arch) assetName=\(assetName)")

    guard let url  = URL(string: "https://api.github.com/repos/actions/runner/releases/latest"),
          let data = try? Data(contentsOf: url) else {
        log("fetchRunnerDownloadURL › failed to fetch release JSON")
        return nil
    }
    struct Asset:   Decodable { let name: String; let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey { case name; case browserDownloadUrl = "browser_download_url" }
    }
    struct Release: Decodable { let assets: [Asset] }
    guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
        log("fetchRunnerDownloadURL › decode failed")
        return nil
    }
    let match = release.assets.first { $0.name.hasPrefix(assetName) && $0.name.hasSuffix(".tar.gz") }
    log("fetchRunnerDownloadURL › match=\(match?.name ?? "nil")")
    return match?.browserDownloadUrl
}
// swiftlint:enable type_body_length
