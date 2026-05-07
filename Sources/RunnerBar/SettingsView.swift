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

    private var runnerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Runner management")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                // Phase 3: Add Runner button (token required)
                if isAuthenticated {
                    Button(
                        action: { showingAddRunnerSheet = true },
                        label: {
                        Image(systemName: "plus").font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Add new runner")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            // Section 1: Local Runners (auto-discovered, no token needed)
            if !store.runners.isEmpty {
                ForEach(store.runners, id: \.id) { runner in
                    runnerRow(runner)
                }
            } else {
                Text("No runners configured")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }

            // Scopes section (existing functionality)
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
        .sheet(isPresented: $showingAddRunnerSheet) {
            AddRunnerView(onDismiss: { showingAddRunnerSheet = false })
        }
    }

    @State private var showingAddRunnerSheet = false

    private func runnerRow(_ runner: Runner) -> some View {
        HStack(spacing: 8) {
            Circle().fill(runnerDotColor(for: runner)).frame(width: 8, height: 8)
            Text(runner.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            // Phase 2: Lifecycle controls (shown for local runners)
            if runner.isLocal {
                lifecycleControls(for: runner)
            }
            Text(runner.displayStatus)
                .font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func lifecycleControls(for runner: Runner) -> some View {
        HStack(spacing: 4) {
            // Resume/Stop button
            Button(action: { toggleRunner(runner) }) {
                Image(systemName: runner.status == "online" ? "stop.fill" : "play.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help(runner.status == "online" ? "Stop runner" : "Start runner")

            // Remove button
            Button(action: { removeRunner(runner) }) {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .help("Remove runner")
        }
    }

    private func toggleRunner(_ runner: Runner) {
        // Phase 2: Use launchctl to start/stop runner
        let action = runner.status == "online" ? "stop" : "start"
        let command = "launchctl \(action) actions.runner.*.\(runner.name)"
        _ = shell(command, timeout: 10)
        log("toggleRunner › \(action) \(runner.name)")
        store.reload()
    }

    private func removeRunner(_ runner: Runner) {
        // Phase 2: Show confirmation alert before removing
        let alert = NSAlert()
        alert.messageText = "Remove Runner \"\(runner.name)\"?"
        alert.informativeText = "This will uninstall the runner from your system."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // Run svc.sh uninstall and config.sh remove
            if let installPath = runner.installPath {
                let runnerDir = (installPath as NSString).deletingLastPathComponent
                _ = shell("cd \"\(runnerDir)\" && ./svc.sh uninstall", timeout: 30)
                _ = shell("cd \"\(runnerDir)\" && ./config.sh remove --token $(gh auth token)", timeout: 30)
            }
            log("removeRunner › removed \(runner.name)")
            store.reload()
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
