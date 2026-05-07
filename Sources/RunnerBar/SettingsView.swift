import ServiceManagement
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - SettingsView

/// Settings view — complete implementation for all phases 1-6.
///
/// Sections: Runner Management, Notifications, General, Account, Legal, About.
/// All persistent state is backed by dedicated ObservableObject stores.
///
/// Phase 1 (issue #251): Local Runners section auto-populates at launch via
/// `LocalRunnerStore`, which calls `LocalRunnerScanner` on a background thread.
/// No GitHub token is required for this section.
struct SettingsView: View {
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @ObservedObject private var legal = LegalPrefsStore.shared
    /// Drives the Local Runners section (Phase 1 — no token required).
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

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
                    localRunnersSection
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
            // Phase 1: trigger local runner scan immediately on appear (no token needed)
            localRunnerStore.refresh()
        }
        .onDisappear {
            // Clear the closure to avoid stale-capture reload after view is gone
            ScopeStore.shared.onMutate = nil
        }
    }

    // MARK: - Sections

    // Explicit label: on all Button(action:label:) calls throughout this file—
    // prevents multiple_closures_with_trailing_closure SwiftLint violations.
    private var headerBar: some View {
        HStack {
            Button(action: onBack, label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Settings")
                        .font(.headline)
                }
                .foregroundColor(.primary)
            })
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: Phase 1 — Local Runners (no GitHub token required)

    /// Section 1: displays all locally-installed runners discovered by
    /// `LocalRunnerScanner`. Renders instantly at launch without any API call.
    /// Status dots reflect whether the runner process is live on this machine.
    private var localRunnersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local runners")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if localRunnerStore.isScanning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Button(action: { localRunnerStore.refresh() }, label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    })
                    .buttonStyle(.plain)
                    .help("Refresh local runner list")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if localRunnerStore.runners.isEmpty && !localRunnerStore.isScanning {
                Text("No local runners found")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(localRunnerStore.runners) { runner in
                    localRunnerRow(runner)
                }
            }
        }
    }

    private func localRunnerRow(_ runner: RunnerModel) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(localRunnerDotColor(for: runner))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.runnerName)
                    .font(.system(size: 13)).lineLimit(1)
                if let url = runner.gitHubUrl {
                    Text(url)
                        .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(runner.displayStatus)
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func localRunnerDotColor(for runner: RunnerModel) -> Color {
        switch runner.statusColor {
        case .running: return .green
        case .idle:    return .gray
        case .offline: return .red
        }
    }

    // MARK: - Section 2: API-registered runner scopes (existing)

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
                Button(action: submitScope, label: {
                    Image(systemName: "plus.circle")
                })
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
            // String-label init — no closure on Toggle, so .onChange(perform:) is
            // the sole closure in the chain. Fixes multiple_closures_with_trailing_closure.
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .onChange(of: launchAtLogin, perform: applyLaunchAtLogin)
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
                    Button(action: signInWithGitHub, label: {
                        Text("Sign in").font(.caption).foregroundColor(.orange)
                    }).buttonStyle(.plain)
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

    /// Applies the launch-at-login preference change.
    /// Passed as a function reference to `.onChange(of:perform:)` — no trailing
    /// closure on the Toggle call-chain (fixes multiple_closures_with_trailing_closure).
    private func applyLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
    }

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
