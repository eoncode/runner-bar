import ServiceManagement
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - SettingsView

/// Settings view — complete implementation for all phases 1-6.
///
/// Sections: Runner Management, Notifications, General, Account, Legal, About.
/// All persistent state is backed by dedicated ObservableObject stores.
struct SettingsView: View {
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @ObservedObject private var legal = LegalPrefsStore.shared

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)

    // Add Runner flow state
    @State private var showAddFlow = false
    @State private var addScopeType: AddScopeType = .repo
    @State private var selectedOrg = ""
    @State private var selectedRepo = ""
    @State private var runnerName = ""
    @State private var labels = ""
    @State private var availableOrgs: [String] = []
    @State private var availableRepos: [String] = []

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    enum AddScopeType: String, CaseIterable, Identifiable {
        case repo = "Repo", org = "Org"
        var id: String { self.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    localRunnersSection
                    Divider()
                    addRunnerSection
                    Divider()
                    scopeSection
                    Divider()
                    notificationsSection
                    Divider()
                    generalSection
                    Divider()
                    accountSection
                    Divider()
                    legalSection
                    Divider()
                    aboutSection
                }
                .padding(.bottom, 16)
            }
        }
        // ⚠️ REGRESSION GUARD: keep idealWidth: 420 — matches PopoverMainView (ref #52 #54 #57)
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            ScopeStore.shared.onMutate = { [weak store] in
                store?.reload()
            }
            loadDiscoveryData()
        }
        .onDisappear {
            // Clear the closure to avoid stale-capture reload after view is gone
            ScopeStore.shared.onMutate = nil
        }
    }

    // MARK: - Sections

    private var headerBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Settings")
                        .font(.headline)
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
    }

    private var localRunnersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Local Runners")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if store.localRunners.isEmpty {
                Text("No local runners discovered")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(store.localRunners, id: \.id) { runner in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(runner.isRunning ? Color.green : Color.gray).frame(width: 8, height: 8)
                            Text(runner.name).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            HStack(spacing: 12) {
                                Button(action: { toggleRunner(runner) }) {
                                    Image(systemName: runner.isRunning ? "stop.fill" : "play.fill")
                                        .foregroundColor(runner.isRunning ? .red : .green)
                                }.buttonStyle(.plain)

                                Button(action: { removeRunner(runner) }) {
                                    Image(systemName: "trash").foregroundColor(.secondary)
                                }.buttonStyle(.plain)
                            }
                        }
                        if let url = runner.gitHubUrl {
                            Text(url).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private var addRunnerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Runner")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: { withAnimation { showAddFlow.toggle() } }) {
                    Image(systemName: showAddFlow ? "minus.circle" : "plus.circle")
                        .foregroundColor(.blue)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if showAddFlow {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Scope", selection: $addScopeType) {
                        ForEach(AddScopeType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    if addScopeType == .org {
                        Picker("Organization", selection: $selectedOrg) {
                            Text("Select an org").tag("")
                            ForEach(availableOrgs, id: \.self) { org in
                                Text(org).tag(org)
                            }
                        }
                    } else {
                        Picker("Repository", selection: $selectedRepo) {
                            Text("Select a repo").tag("")
                            ForEach(availableRepos, id: \.self) { repo in
                                Text(repo).tag(repo)
                            }
                        }
                    }

                    TextField("Runner Name", text: $runnerName)
                        .textFieldStyle(.roundedBorder)

                    TextField("Labels (comma separated)", text: $labels)
                        .textFieldStyle(.roundedBorder)

                    Button(action: performAddRunner) {
                        Text("Configure and Start")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runnerName.isEmpty || (addScopeType == .org ? selectedOrg.isEmpty : selectedRepo.isEmpty))
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scopes").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(ScopeStore.shared.scopes, id: \.self) { scopeStr in
                HStack {
                    Text(scopeStr).font(.system(size: 12))
                    Spacer()
                    Button(action: {
                        ScopeStore.shared.remove(scopeStr)
                        RunnerStore.shared.start()
                    }, label: {
                        Image(systemName: "minus.circle").foregroundColor(.red)
                    }).buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 2)
            }
            HStack {
                TextField("owner/repo or org", text: $newScope)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit { submitScope() }
                Button(action: submitScope) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Toggle(isOn: $notifications.notifyOnSuccess) {
                Text("Notify on success").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            Toggle(isOn: $notifications.notifyOnFailure) {
                Text("Notify on failure").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .onChange(of: launchAtLogin) { _, newValue in
                LoginItem.setEnabled(newValue)
            }
            Divider().padding(.leading, 12)
            Toggle(isOn: $settings.showDimmedRunners) {
                Text("Show offline runners").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            HStack {
                Text("Polling interval").font(.system(size: 12))
                Spacer()
                Text("\(settings.pollingInterval)s")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper("", value: $settings.pollingInterval, in: 10...300)
                    .labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("GitHub").font(.system(size: 12))
                Spacer()
                if isAuthenticated {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Authenticated").font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Button(action: signInWithGitHub) {
                        Text("Sign in").font(.caption).foregroundColor(.orange)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().padding(.leading, 12)
            // Auth reads token via: gh auth token > GH_TOKEN > GITHUB_TOKEN (see Auth.swift).
            Text("Run `gh auth login` in Terminal, or set GH_TOKEN / GITHUB_TOKEN env var.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Legal")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Toggle(isOn: $legal.analyticsEnabled) {
                Text("Share analytics").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12).padding(.vertical, 6)
#if DEBUG
            // ⚠️ Placeholder links — gated behind DEBUG so they never ship to users.
            Divider().padding(.leading, 12)
            linkRow(label: "Privacy Policy", url: "https://github.com/eoncode/runner-bar")
            Divider().padding(.leading, 12)
            linkRow(label: "EULA", url: "https://github.com/eoncode/runner-bar")
#endif
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("About")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            HStack {
                Text("Version").font(.system(size: 12))
                Spacer()
                Text("\(appVersion) (\(appBuild))")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
            HStack {
                Text("RunnerBar").font(.system(size: 12))
                Spacer()
                Text(Bundle.main.bundleIdentifier ?? "dev.eonist.runnerbar")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
            Text("A macOS menu bar utility for monitoring GitHub Actions self-hosted runners.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
        }
    }

    // MARK: - Helpers

    private func loadDiscoveryData() {
        DispatchQueue.global(qos: .userInitiated).async {
            let orgs = fetchUserOrgs()
            let repos = fetchUserRepos()
            DispatchQueue.main.async {
                self.availableOrgs = orgs
                self.availableRepos = repos
            }
        }
    }

    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }

    private func toggleRunner(_ runner: Runner) {
        let cmd = runner.isRunning ? "stop" : "start"
        // Use the install path to find the plist or just use the name if we follow convention
        // GitHub runners typically install plists with a specific naming scheme
        // including the owner and repo.
        let plistName = runner.installPath.flatMap { path -> String? in
            let folder = (path as NSString).appendingPathComponent("Library/LaunchAgents")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return files.first { $0.contains(runner.name) && $0.hasSuffix(".plist") }
        } ?? "actions.runner.\(runner.name).plist"

        let escapedPlist = shellEscape((NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/\(plistName)"))
        shell("launchctl \(cmd) \(escapedPlist)")
        RunnerStore.shared.reload()
    }

    private func removeRunner(_ runner: Runner) {
        guard let path = runner.installPath else { return }
        let escapedPath = shellEscape(path)
        shell("cd \(escapedPath) && ./svc.sh uninstall && ./config.sh remove")
        RunnerStore.shared.reload()
    }

    private func performAddRunner() {
        let scope = addScopeType == .org ? selectedOrg : selectedRepo
        DispatchQueue.global(qos: .userInitiated).async {
            if let token = fetchRegistrationToken(scope: scope) {
                let escapedScope = shellEscape(scope)
                let escapedToken = shellEscape(token)
                let escapedName = shellEscape(runnerName)
                let escapedLabels = shellEscape(labels)

                shell("./config.sh --url https://github.com/\(escapedScope) --token \(escapedToken) --name \(escapedName) --labels \(escapedLabels)")
                shell("./svc.sh install && ./svc.sh start")

                DispatchQueue.main.async {
                    showAddFlow = false
                    RunnerStore.shared.reload()
                }
            }
        }
    }

    /// Rudimentary shell escaping for safety.
    private func shellEscape(_ input: String) -> String {
        "'" + input.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func linkRow(label: String, url: String) -> some View {
        Button(
            action: { if let dest = URL(string: url) { NSWorkspace.shared.open(dest) } },
            label: {
                HStack {
                    Text(label).font(.system(size: 12)).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        ).buttonStyle(.plain)
    }

    /// Opens the GitHub PAT setup docs in the default browser.
    /// Device-flow URL requires a user_code the app never generates — PAT docs are correct (ref #221).
    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
// swiftlint:enable type_body_length
