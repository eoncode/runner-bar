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
struct AddRunnerSheet: View {
    @Binding var isPresented: Bool
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
    @State private var installDir  = (FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("actions-runner").path)

    // MARK: Registration state

    @State private var isRegistering = false
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add runner")
                .font(.headline)

            // Scope type picker
            Picker("Scope", selection: $scopeType) {
                ForEach(ScopeType.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)

            // Org / Repo selector
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
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organisation").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $selectedOrg) {
                        Text("— select —").tag("")
                        ForEach(orgs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            // Runner name
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner name").font(.caption).foregroundColor(.secondary)
                TextField("e.g. my-mac-runner", text: $runnerName)
                    .textFieldStyle(.roundedBorder)
            }

            // Labels
            VStack(alignment: .leading, spacing: 4) {
                Text("Labels (comma-separated)").font(.caption).foregroundColor(.secondary)
                TextField("e.g. self-hosted,macOS,arm64", text: $labelsText)
                    .textFieldStyle(.roundedBorder)
            }

            // Install directory
            VStack(alignment: .leading, spacing: 4) {
                Text("Runner install directory").font(.caption).foregroundColor(.secondary)
                TextField("", text: $installDir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            // Error banner
            if let err = errorMessage {
                Text(err)
                    .font(.caption).foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }

            // Actions
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
            let fetchedOrgs  = fetchUserOrgs()
            DispatchQueue.main.async {
                repos = fetchedRepos
                orgs  = fetchedOrgs
                if let first = fetchedRepos.first { selectedRepo = first }
                if let firstOrg = fetchedOrgs.first { selectedOrg = firstOrg }
                isLoadingScopes = false
            }
        }
    }

    private func register() {
        guard canRegister else { return }
        errorMessage = nil
        isRegistering = true
        let scope    = effectiveScope
        let name     = runnerName.trimmingCharacters(in: .whitespaces)
        let labels   = labelsText.trimmingCharacters(in: .whitespaces)
        let dir      = installDir.trimmingCharacters(in: .whitespaces)

        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Fetch registration token
            guard let token = fetchRegistrationToken(scope: scope) else {
                DispatchQueue.main.async {
                    isRegistering = false
                    errorMessage = "Failed to fetch registration token. " +
                        "Ensure `gh auth login` has been run or GH_TOKEN is set."
                }
                return
            }

            // 2. Determine GitHub URL from scope
            let ghURL: String
            if scope.contains("/") {
                ghURL = "https://github.com/\(scope)"
            } else {
                ghURL = "https://github.com/\(scope)"
            }

            // 3. Ensure install dir exists
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )

            // 4. Run config.sh
            let labelArg = labels.isEmpty ? "" : " --labels \"\(labels)\""
            let cmd = "cd \"\(dir)\" && ./config.sh" +
                " --url \"\(ghURL)\"" +
                " --token \"\(token)\"" +
                " --name \"\(name)\"" +
                labelArg +
                " --unattended 2>&1"
            let output = shell(cmd, timeout: 60)
            let failed = output.lowercased().contains("error")
                || output.lowercased().contains("failed")

            DispatchQueue.main.async {
                isRegistering = false
                if failed {
                    errorMessage = "config.sh failed: \(output.prefix(200))"
                } else {
                    isPresented = false
                    onComplete()
                }
            }
        }
    }
}
