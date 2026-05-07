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
            let json = shell("/opt/homebrew/bin/gh api /user/orgs")
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
            let json = shell("/opt/homebrew/bin/gh api /user/repos?per_page=100")
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
            
            // Step 2: Run config.sh with token
            let labelsArg = labels.isEmpty ? "" : "--labels \(labels)"
            let configCmd = """
                mkdir -p ~/actions-runner-\(scope)-\(runnerName) && \
                cd ~/actions-runner-\(scope)-\(runnerName) && \
                curl -O -L https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-osx-arm64-2.322.0.tar.gz && \
                tar xzf actions-runner-osx-arm64-2.322.0.tar.gz && \
                ./config.sh --url https://github.com/\(scope) --token \(tokenResp.token) --name \(runnerName) \(labelsArg) --unattended
            """
            
            let configResult = shell(configCmd, timeout: 120)
            
            if configResult.contains("Added") {
                // Step 3: Install as service
                _ = shell("cd ~/actions-runner-\(scope)-\(runnerName) && ./svc.sh install", timeout: 30)
                
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

// MARK: - Codable Responses

private struct OrgResponse: Codable {
    let login: String
}

private struct RepoResponse: Codable {
    let fullName: String
    
    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
    }
}

private struct RegistrationTokenResponse: Codable {
    let token: String
}
