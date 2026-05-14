// swiftlint:disable file_length
import ServiceManagement
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - SettingsView

/// Settings view — complete implementation for all phases 1-6.
///
/// Sections: Runner Management, Notifications, General, Account, Legal, About.
/// All persistent state is backed by dedicated ObservableObject stores.
///
/// Phase 1 (issue #252): Local Runners section auto-populates at launch via
/// `LocalRunnerStore`, which calls `LocalRunnerScanner` on a background thread.
/// No GitHub token is required for this section.
///
/// Phase 2 (issue #253): Each runner row gains Resume/Stop, ⚙ Config, and
/// ✕ Remove controls backed by `RunnerLifecycleService`.
///
/// Phase 3 (issue #254): A `+` button in the Local Runners header opens
/// `AddRunnerSheet` to onboard new runners via the GitHub API.
///
/// Phase 4 (issue #255): `RunnerStatusEnricher` enriches runner rows with
/// live GitHub API status (online/offline/busy) after each local scan.
///
/// ⚠️ ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize (ref #377).
/// AppDelegate KVO-observes preferredContentSize and calls NSPanel.setFrame().
/// NSPanel.setFrame() has no anchor → zero side jump on any size change.
///
/// HEIGHT CONTRACT:
/// NO ScrollView, NO frame(maxHeight:) cap.
/// preferredContentSize reports the full natural VStack height.
/// AppDelegate.resizeAndRepositionPanel() clamps to maxHeight = 85% screen.
/// That is the only height cap — enforced at the AppDelegate level, not here.
/// ❌ NEVER add a ScrollView or frame(maxHeight:) cap back to SettingsView.
/// ❌ NEVER add idealHeight to the root frame.
///
/// WIDTH CONTRACT:
/// .frame(idealWidth: 480) — only idealWidth needed. NSPanel handles bounds.
/// ❌ NEVER remove idealWidth: 480.
///
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
/// is major major major.
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
    /// Becomes `true` after the first scan completes.
    @State private var hasLoadedOnce = false
    /// Phase 2: runner pending removal confirmation.
    @State private var runnerPendingRemoval: RunnerModel?
    /// Phase 2: runner whose config sheet is open.
    @State private var runnerBeingConfigured: RunnerModel?
    /// Phase 3: controls whether the Add Runner sheet is presented.
    @State private var showAddRunnerSheet = false
    /// Surfaced when remove() returns false — cleared on next refresh.
    @State private var removeErrorMessage: String?
    /// `true` while `gh auth logout` is in flight — disables the button to prevent double-tap.
    @State private var isSigningOut = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// Alert title for the runner-removal confirmation dialog.
    private var removalAlertTitle: String {
        let name = runnerPendingRemoval?.runnerName ?? "this runner"
        return "Remove runner \"\(name)\""
    }

    var body: some View {
        // NO ScrollView — NSPanel grows to show all content.
        // AppDelegate clamps panel height to 85% screen visibleFrame.
        // ❌ NEVER wrap in ScrollView or add frame(maxHeight:) here.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
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
        // idealWidth only — no idealHeight. NSPanel handles screen bounds.
        // ❌ NEVER add idealHeight here.
        // ❌ NEVER remove idealWidth: 480.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            ScopeStore.shared.onMutate = { [weak store] in
                store?.reload()
            }
            localRunnerStore.refresh()
        }
        // Single-parameter form: compatible with macOS 13+.
        // The two-parameter { _, newValue in } form requires macOS 14+.
        .onChange(of: localRunnerStore.isScanning) { scanning in
            if !scanning { hasLoadedOnce = true }
        }
        .onDisappear {
            ScopeStore.shared.onMutate = nil
        }
        .sheet(isPresented: $showAddRunnerSheet) {
            AddRunnerSheet(isPresented: $showAddRunnerSheet) {
                localRunnerStore.refresh()
            }
        }
        .sheet(item: $runnerBeingConfigured) { runner in
            RunnerConfigSheet(runner: runner, isPresented: $runnerBeingConfigured) {
                localRunnerStore.refresh()
            }
        }
        .alert(removalAlertTitle, isPresented: Binding(
            get: { runnerPendingRemoval != nil },
            set: { if !$0 { runnerPendingRemoval = nil } }
        )) {
            Button("Cancel", role: .cancel) { runnerPendingRemoval = nil }
            Button("Remove", role: .destructive) {
                guard let runner = runnerPendingRemoval else { return }
                guard isAuthenticated else {
                    runnerPendingRemoval = nil
                    return
                }
                runnerPendingRemoval = nil
                removeErrorMessage = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    let succeeded = RunnerLifecycleService.shared.remove(runner: runner)
                    DispatchQueue.main.async {
                        if !succeeded {
                            removeErrorMessage = "De-registration failed — the runner may " +
                                "still appear in GitHub. Check your token and try again."
                        }
                        localRunnerStore.refresh()
                    }
                }
            }
        } message: {
            if isAuthenticated {
                Text("This will run ./svc.sh uninstall and ./config.sh remove. " +
                     "A GitHub token is required for de-registration.")
            } else {
                Text("A GitHub token is required to de-register the runner from GitHub. " +
                     "Sign in via `gh auth login` or set GH_TOKEN, then try again.")
            }
        }
    }

    // MARK: - Sections

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

    // MARK: Phase 1 + 2 + 4 — Local Runners

    private var localRunnersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local runners")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: { showAddRunnerSheet = true }, label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(.secondary)
                })
                .buttonStyle(.plain)
                .help("Add a new runner")
                .padding(.trailing, 4)
                if localRunnerStore.isScanning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Button(action: {
                        removeErrorMessage = nil
                        localRunnerStore.refresh()
                    }, label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    })
                    .buttonStyle(.plain)
                    .help("Refresh local runner list")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if let errMsg = removeErrorMessage {
                Text(errMsg)
                    .font(.caption).foregroundColor(.red)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.red.opacity(0.07))
            }

            if localRunnerStore.runners.isEmpty && !localRunnerStore.isScanning && hasLoadedOnce {
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
        HStack(spacing: 6) {
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
            if runner.isRunning {
                Button(
                    action: {
                        lifecycleAction { RunnerLifecycleService.shared.stop(runner: runner) }
                    },
                    label: { Text("Stop").font(.caption2) }
                )
                .buttonStyle(.bordered)
                .help("Stop runner service")
            } else {
                Button(
                    action: {
                        lifecycleAction { RunnerLifecycleService.shared.start(runner: runner) }
                    },
                    label: { Text("Resume").font(.caption2) }
                )
                .buttonStyle(.bordered)
                .help("Start runner service")
            }
            Button(action: { runnerBeingConfigured = runner }, label: {
                Image(systemName: "gearshape").font(.caption2)
            })
            .buttonStyle(.plain)
            .help("Configure runner")
            Button(action: { runnerPendingRemoval = runner }, label: {
                Image(systemName: "minus.circle").font(.caption2).foregroundColor(.red)
            })
            .buttonStyle(.plain)
            .help("Remove runner")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func lifecycleAction(_ action: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            action()
            DispatchQueue.main.async { localRunnerStore.refresh() }
        }
    }

    private func localRunnerDotColor(for runner: RunnerModel) -> Color {
        switch runner.statusColor {
        case .running: return .green
        case .busy: return .yellow
        case .idle: return .gray
        case .offline: return .red
        }
    }

    // MARK: - Section 2: API-registered runner scopes

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
            HStack {
                Text("Notify on success").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $notifications.notifyOnSuccess)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            HStack {
                Text("Notify on failure").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $notifications.notifyOnFailure)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Launch at login").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: launchAtLogin, perform: applyLaunchAtLogin)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            // ── Show offline runners ───────────────────────────────────────────────
            HStack {
                Text("Show offline runners").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $settings.showDimmedRunners)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            Text("When enabled, runners that are offline or unreachable are shown dimmed in the list.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 6)
            Divider().padding(.leading, 12)
            // ── Polling interval ───────────────────────────────────────────────
            HStack {
                Text("Polling interval").font(.system(size: 12))
                Spacer()
                Text("\(settings.pollingInterval)s")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper("", value: $settings.pollingInterval, in: 10...300)
                    .labelsHidden()
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            Text("How often RunnerBar checks GitHub for runner and workflow status. Lower values use more API quota.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    // MARK: - Account section
    //
    // When authenticated, shows:
    //   GitHub   ● Authenticated   [Sign out]
    //
    // Sign out runs `gh auth logout --hostname github.com` on a background
    // thread, then re-checks githubToken() to refresh isAuthenticated.
    // isSigningOut disables the button while the shell call is in flight.
    //
    // ❌ NEVER remove the `gh auth login` hint below — it is the only
    //    recovery path shown to the user after signing out.
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("GitHub").font(.system(size: 12))
                Spacer()
                if isAuthenticated {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("Authenticated").font(.caption).foregroundColor(.secondary)
                        }
                        Button(action: signOutOfGitHub) {
                            Text("Sign out")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSigningOut)
                        .help("Run gh auth logout and disconnect RunnerBar from GitHub")
                    }
                } else {
                    Button(action: signInWithGitHub, label: {
                        Text("Sign in").font(.caption).foregroundColor(.orange)
                    }).buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().padding(.leading, 12)
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
            HStack {
                Text("Share analytics").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $legal.analyticsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
#if DEBUG
            Divider().padding(.leading, 12)
            linkRow(label: "Privacy Policy", url: "https://github.com/eoncode/runner-bar") // NOSONAR S1075 — user-facing navigation URL
            Divider().padding(.leading, 12)
            linkRow(label: "EULA", url: "https://github.com/eoncode/runner-bar") // NOSONAR S1075 — user-facing navigation URL
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

    /// Returns the dot colour for an API-registered `Runner` row.
    /// Flattened from a nested ternary to a guard+return for readability (S3358).
    private func runnerDotColor(for runner: Runner) -> Color {
        guard runner.status == "online" else { return .gray }
        return runner.busy ? .yellow : .green
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

    private func signInWithGitHub() {
        // NOSONAR S1075 — user-facing docs URL, not a configurable system path
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Runs `gh auth logout --hostname github.com` on a background thread.
    /// Updates `isAuthenticated` on the main thread when the call completes.
    /// Uses `isSigningOut` to prevent double-tap.
    ///
    /// ❌ NEVER run shell calls on the main thread — they block the UI.
    private func signOutOfGitHub() {
        guard !isSigningOut else { return }
        isSigningOut = true
        DispatchQueue.global(qos: .userInitiated).async {
            // ghBinaryPath() avoids a hard-coded /opt/homebrew/bin/gh path (S1075).
            if let ghPath = ghBinaryPath() {
                _ = shell("\(ghPath) auth logout --hostname github.com")
            }
            DispatchQueue.main.async {
                isAuthenticated = (githubToken() != nil)
                isSigningOut = false
            }
        }
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
