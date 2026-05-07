import Foundation
import ServiceManagement
import SwiftUI

// swiftlint:disable type_body_length file_length
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

    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @ObservedObject private var legal = LegalPrefsStore.shared

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)

    // MARK: - Phase 3: Add Runner State
    @State private var showAddFlow = false
    @State private var addScopeType: AddScopeType = .repo
    @State private var selectedOrg = ""
    @State private var selectedRepo = ""
    @State private var runnerName = ""
    @State private var labels = ""
    @State private var isAddingRunner = false
    @State private var errorMessage: String?

    @State private var userOrgs: [String] = []
    @State private var userRepos: [String] = []

    enum AddScopeType { case org, repo }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
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
                    runnerSection
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
            localRunnerStore.refresh()
            if isAuthenticated {
                loadDiscoveryData()
            }
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

    private var addRunnerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { showAddFlow.toggle() } }, label: {
                HStack {
                    Text("Add new runner")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: showAddFlow ? "minus.circle" : "plus.circle")
                        .font(.caption).foregroundColor(.secondary)
                }
            })
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if showAddFlow {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Scope", selection: $addScopeType) {
                        Text("Repository").tag(AddScopeType.repo)
                        Text("Organization").tag(AddScopeType.org)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if addScopeType == .org {
                        Picker("Organization", selection: $selectedOrg) {
                            Text("Select an organization").tag("")
                            ForEach(userOrgs, id: \.self) { org in
                                Text(org).tag(org)
                            }
                        }
                    } else {
                        Picker("Repository", selection: $selectedRepo) {
                            Text("Select a repository").tag("")
                            ForEach(userRepos, id: \.self) { repo in
                                Text(repo).tag(repo)
                            }
                        }
                    }

                    TextField("Runner name", text: $runnerName)
                        .textFieldStyle(.roundedBorder)

                    TextField("Labels (comma separated, optional)", text: $labels)
                        .textFieldStyle(.roundedBorder)

                    if let error = errorMessage {
                        Text(error).font(.caption).foregroundColor(.red)
                    }

                    Button(action: performAddRunner) {
                        HStack {
                            if isAddingRunner {
                                ProgressView().controlSize(.small).scaleEffect(0.5)
                            }
                            Text(isAddingRunner ? "Configuring..." : "Configure and Start")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAddingRunner || runnerName.isEmpty ||
                              (addScopeType == .org ? selectedOrg.isEmpty : selectedRepo.isEmpty))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var localRunnersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local runners")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if localRunnerStore.isScanning {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Button(action: { localRunnerStore.refresh() }, label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption).foregroundColor(.secondary)
                    }).buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if localRunnerStore.runners.isEmpty && !localRunnerStore.isScanning {
                Text("No local runners found")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(localRunnerStore.runners) { runner in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(localRunnerDotColor(for: runner))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(runner.runnerName)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            if let url = runner.gitHubUrl {
                                Text(url)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption).foregroundColor(.secondary)

                        // Phase 2: Lifecycle controls
                        if runner.launchLabel != nil {
                            Button(action: { toggleRunner(runner) }, label: {
                                Image(systemName: runner.isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 10))
                            })
                            .buttonStyle(.plain)
                            .help(runner.isRunning ? "Stop runner" : "Start runner")
                        }

                        if runner.installPath != nil {
                            Button(action: { removeRunner(runner) }, label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                            })
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            .help("Remove runner")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }
        }
    }

    private var runnerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Runner management")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            if !store.runners.isEmpty {
                ForEach(store.runners, id: \.id) { runner in
                    HStack(spacing: 8) {
                        Circle().fill(runnerDotColor(for: runner)).frame(width: 8, height: 8)
                        Text(runner.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            } else {
                Text("No runners configured")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
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

    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }

    private func runnerDotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }

    private func localRunnerDotColor(for runner: RunnerModel) -> Color {
        switch runner.statusColor {
        case .running: return .green
        case .idle: return .gray
        case .offline: return .red
        }
    }

    // MARK: - Phase 2: Lifecycle Helpers

    private func toggleRunner(_ runner: RunnerModel) {
        guard let label = runner.launchLabel else { return }
        let action = runner.isRunning ? "stop" : "start"

        // Execute on background queue to avoid UI freeze
        DispatchQueue.global(qos: .userInitiated).async {
            shell("launchctl \(action) \(shellEscape(label))")

            Task { @MainActor in
                localRunnerStore.refresh()
            }
        }
    }

    private func removeRunner(_ runner: RunnerModel) {
        let alert = NSAlert()
        alert.messageText = "Remove Runner \"\(runner.runnerName)\"?"
        alert.informativeText = "This will uninstall the runner service and remove its configuration."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Execute on background queue to avoid UI freeze
        DispatchQueue.global(qos: .userInitiated).async {
            if let path = runner.installPath {
                // 1. Uninstall the service (svc.sh uninstall)
                shell("cd \(shellEscape(path)) && ./svc.sh uninstall")

                // 2. Remove registration (config.sh remove)
                // We need a removal token for non-interactive removal.
                if let url = runner.gitHubUrl, let scope = extractScope(from: url) {
                    if let token = fetchRemovalToken(scope: scope) {
                        shell("cd \(shellEscape(path)) && ./config.sh remove --token \(shellEscape(token))")
                    } else {
                        log("removeRunner › failed to fetch removal token for \(scope)")
                        // Fallback to interactive-style remove
                        shell("cd \(shellEscape(path)) && ./config.sh remove")
                    }
                }
            }

            Task { @MainActor in
                localRunnerStore.refresh()
            }
        }
    }

    // MARK: - Phase 3: Add Runner Helpers

    private func loadDiscoveryData() {
        DispatchQueue.global(qos: .userInitiated).async {
            let orgs = fetchUserOrgs()
            let repos = fetchUserRepos()

            Task { @MainActor in
                self.userOrgs = orgs
                self.userRepos = repos
            }
        }
    }

    private func performAddRunner() {
        let scope = addScopeType == .org ? selectedOrg : selectedRepo
        let nameSnapshot = runnerName
        let labelsSnapshot = labels

        isAddingRunner = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            guard let token = fetchRegistrationToken(scope: scope) else {
                Task { @MainActor in
                    self.errorMessage = "Failed to fetch registration token"
                    self.isAddingRunner = false
                }
                return
            }

            // Create a dedicated directory for the runner
            let home = NSHomeDirectory()
            let sanitizedScope = scope.replacingOccurrences(of: "/", with: "-")
            let dirName = "actions-runner-\(sanitizedScope)-\(nameSnapshot)"
            let installDir = (home as NSString).appendingPathComponent(dirName)

            // 1. Create directory
            shell("mkdir -p \(shellEscape(installDir))")

            // 2. Download latest runner if not present
            let configPath = (installDir as NSString).appendingPathComponent("config.sh")
            if !FileManager.default.fileExists(atPath: configPath) {
                log("performAddRunner › downloading runner binary...")

                let arch = shell("uname -m") == "arm64" ? "arm64" : "x64"
                let version = fetchLatestRunnerVersion() ?? "2.316.1"
                let downloadUrl = "https://github.com/actions/runner/releases/download/" +
                    "v\(version)/actions-runner-osx-\(arch)-\(version).tar.gz"
                let tarball = (installDir as NSString).appendingPathComponent("runner.tar.gz")

                shell("curl -L -o \(shellEscape(tarball)) \(downloadUrl)")
                shell("tar xzf \(shellEscape(tarball)) -C \(shellEscape(installDir))")
            }

            // 3. Configure
            let labelsArg = labelsSnapshot.isEmpty ? "" : "--labels \(shellEscape(labelsSnapshot))"
            let configCmd = "cd \(shellEscape(installDir)) && ./config.sh " +
                "--url https://github.com/\(scope) --token \(shellEscape(token)) " +
                "--name \(shellEscape(nameSnapshot)) \(labelsArg) --unattended"
            let configResult = shell(configCmd)

            if configResult.contains("failed") || configResult.contains("Error") {
                 Task { @MainActor in
                    self.errorMessage = "Configuration failed. Check logs."
                    self.isAddingRunner = false
                }
                return
            }

            // 4. Install and Start service
            shell("cd \(shellEscape(installDir)) && ./svc.sh install")
            shell("cd \(shellEscape(installDir)) && ./svc.sh start")

            Task { @MainActor in
                self.isAddingRunner = false
                self.showAddFlow = false
                self.runnerName = ""
                self.labels = ""
                self.localRunnerStore.refresh()
            }
        }
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
