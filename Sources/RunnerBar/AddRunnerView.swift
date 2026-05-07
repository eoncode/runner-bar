import SwiftUI

/// Phase 3: Add Runner flow — sheet for registering a new self-hosted runner.
/// Token required. Purely additive — never modifies existing runners.
struct AddRunnerView: View {
    let onDismiss: () -> Void

    @State private var scopeType: ScopeType = .repo
    @State private var selectedOrg = ""
    @State private var selectedRepo = ""
    @State private var runnerName = ""
    @State private var labels = ""
    @State private var isFetchingOrgs = false
    @State private var isFetchingRepos = false
    @State private var isRegistering = false
    @State private var errorMessage: String?
    @State private var organizations: [String] = []
    @State private var repositories: [String] = []

    enum ScopeType: String, CaseIterable {
        case repo = "Repository"
        case org = "Organization"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            form
            actionButtons
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            fetchOrganizations()
            fetchRepositories()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Runner").font(.headline)
            Text("Register a new self-hosted runner to your GitHub organization or repository.").font(.subheadline).foregroundColor(.secondary)
        }
    }

    private var form: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Scope type picker
                Picker("Scope", selection: $scopeType) {
                    ForEach(ScopeType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if scopeType == .org {
                    // Organization selector
                    if isFetchingOrgs {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading organizations...").font(.caption).foregroundColor(.secondary)
                    } else {
                        Picker("Organization", selection: $selectedOrg) {
                            Text("Select an organization").tag("")
                            ForEach(organizations, id: \.self) { org in
                                Text(org).tag(org)
                            }
                        }
                    }
                } else {
                    // Repository selector
                    if isFetchingRepos {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading repositories...").font(.caption).foregroundColor(.secondary)
                    } else {
                        Picker("Repository", selection: $selectedRepo) {
                            Text("Select a repository").tag("")
                            ForEach(repositories, id: \.self) { repo in
                                Text(repo).tag(repo)
                            }
                        }
                    }
                }

                // Runner name field
                TextField("Runner name", text: $runnerName)
                    .textFieldStyle(.roundedBorder)

                // Labels field (optional)
                TextField("Labels (comma-separated)", text: $labels)
                    .textFieldStyle(.roundedBorder)

                if let error = errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }
            }
            .padding(8)
        }
    }

    private var actionButtons: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onDismiss)
                .keyboardShortcut(.escape, modifiers: [])
            Button(action: registerRunner) {
                if isRegistering {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text("Add Runner")
                }
            }
            .disabled(!canRegister || isRegistering)
        }
    }

    private var canRegister: Bool {
        let hasScope = scopeType == .org ? !selectedOrg.isEmpty : !selectedRepo.isEmpty
        return hasScope && !runnerName.isEmpty
    }

    // MARK: - API Calls

    private func fetchOrganizations() {
        isFetchingOrgs = true
        DispatchQueue.global(qos: .background).async {
            guard let ghPath = ghBinaryPath() else {
                DispatchQueue.main.async {
                    isFetchingOrgs = false
                }
                return
            }
            let json = shell("\(ghPath) api /user/orgs")
            if let data = json.data(using: .utf8),
               let orgs = try? JSONDecoder().decode([OrgResponse].self, from: data) {
                DispatchQueue.main.async {
                    organizations = orgs.map { $0.login }.sorted()
                    isFetchingOrgs = false
                }
            } else {
                DispatchQueue.main.async {
                    isFetchingOrgs = false
                }
            }
        }
    }

    private func fetchRepositories() {
        isFetchingRepos = true
        DispatchQueue.global(qos: .background).async {
            guard let ghPath = ghBinaryPath() else {
                DispatchQueue.main.async {
                    isFetchingRepos = false
                }
                return
            }
            let json = shell("\(ghPath) api /user/repos?per_page=100")
            if let data = json.data(using: .utf8),
               let repos = try? JSONDecoder().decode([RepoResponse].self, from: data) {
                DispatchQueue.main.async {
                    repositories = repos.map { $0.fullName }.sorted()
                    isFetchingRepos = false
                }
            } else {
                DispatchQueue.main.async {
                    isFetchingRepos = false
                }
            }
        }
    }

    private func registerRunner() {
        isRegistering = true
        errorMessage = nil

        let scope = scopeType == .org ? selectedOrg : selectedRepo
        let endpoint = scopeType == .org ? "/orgs/\(scope)/actions/runners/registration-token" : "/repos/\(scope)/actions/runners/registration-token"


        // Validate runner name: alphanumeric, hyphen, underscore only
        let nameRegex = #"^[a-zA-Z0-9_-]+$"#
        guard NSPredicate(format: "SELF MATCHES %@", nameRegex).evaluate(with: runnerName) else {
            errorMessage = "Runner name must contain only letters, numbers, hyphens, and underscores."
            isRegistering = false
            return
        }

        // Validate labels: alphanumeric, comma, hyphen, underscore only
        if !labels.isEmpty {
            let labelsRegex = #"^[a-zA-Z0-9,_-]+$"#
            guard NSPredicate(format: "SELF MATCHES %@", labelsRegex).evaluate(with: labels) else {
                errorMessage = "Labels must contain only letters, numbers, commas, hyphens, and underscores."
                isRegistering = false
                return
            }
        }

        DispatchQueue.global(qos: .background).async {
            // Step 1: Get registration token
            guard let tokenData = ghAPI(endpoint),
                  let tokenResp = try? JSONDecoder().decode(RegistrationTokenResponse.self, from: tokenData) else {
                DispatchQueue.main.async {
                    errorMessage = "Failed to get registration token. Ensure you're authenticated."
                    isRegistering = false
                }
                return
            }

            // Step 2: Detect architecture and fetch latest version
            let archScript = "uname -m"
            let archResult = shell(archScript, timeout: 5)
            let arch: String = archResult.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" ? "osx-arm64" : "osx-x64"

            // Fetch latest runner version from GitHub Releases API
            let ghPath = ghBinaryPath() ?? "/opt/homebrew/bin/gh"
            let releaseJson = shell("\(ghPath) api /repos/actions/runner/releases/latest", timeout: 30)
            var version = "2.322.0" // fallback
            if let jsonData = releaseJson.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                version = tagName.replacingOccurrences(of: "v", with: "")
            }

            let tarballName = "actions-runner-\(arch)-\(version).tar.gz"
            let downloadUrl = "https://github.com/actions/runner/releases/download/v\(version)/\(tarballName)"
            let labelsArg = labels.isEmpty ? "" : "--labels \(labels)"
            let configCmd = """
                mkdir -p ~/actions-runner-\(scope)-\(runnerName) && \\
                cd ~/actions-runner-\(scope)-\(runnerName) && \\
                curl -O -L \(downloadUrl) && \\
                tar xzf \(tarballName) && \\
                ./config.sh --url https://github.com/\(scope) --token \(tokenResp.token) --name \(runnerName) \(labelsArg) --unattended
            """

            let configResult = shell(configCmd, timeout: 120)

            if configResult.contains("Added") {
                // Step 3: Install as service
                _ = shell("cd ~/actions-runner-\(scope)-\(runnerName) && ./svc.sh install", timeout: 30)

                // Step 4: Start the service
                _ = shell("cd ~/actions-runner-\(scope)-\(runnerName) && ./svc.sh start", timeout: 30)

                DispatchQueue.main.async {
                    log("registerRunner › successfully registered \(runnerName)")
                    RunnerStore.shared.start()
                    onDismiss()
                }
            } else {
                DispatchQueue.main.async {
                    errorMessage = "Failed to configure runner. Check logs for details."
                    isRegistering = false
                }
            }
        }
    }
}
