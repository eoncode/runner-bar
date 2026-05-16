// swiftlint:disable file_length
import SwiftUI

// swiftlint:disable type_body_length
// MARK: - SettingsView

/// Settings view — complete implementation for all phases 1-6.
///
/// Sections: Local Runners, Runner Management + Scopes, Notifications, General, Account, Legal, About.
/// All persistent state is backed by dedicated ObservableObject stores.
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

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @ObservedObject private var legal = LegalPrefsStore.shared
    @ObservedObject private var scopeStore = ScopeStore.shared
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared
    @EnvironmentObject private var observable: RunnerStoreObservable

    @State private var newScope = ""
    @State private var hasLoadedOnce = false
    @State private var runnerPendingRemoval: RunnerModel?
    @State private var runnerBeingConfigured: Runner?
    @State private var showAddRunnerSheet = false
    @State private var removeErrorMessage: String?
    @State private var isSigningOut = false

    private var isAuthenticated: Bool { !ghToken().isEmpty }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    private var removalAlertTitle: String {
        "Remove runner \"\(runnerPendingRemoval?.runnerName ?? "this runner")\""
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
        // ❌ NEVER add idealHeight here. ❌ NEVER remove idealWidth: 480.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear { localRunnerStore.refresh() }
        .onChange(of: localRunnerStore.isScanning) { scanning in
            if !scanning { hasLoadedOnce = true }
        }
        .sheet(isPresented: $showAddRunnerSheet) { AddRunnerSheet() }
        .sheet(item: $runnerBeingConfigured) { runner in RunnerConfigSheet(runner: runner) }
        .alert(removalAlertTitle, isPresented: Binding(
            get: { runnerPendingRemoval != nil },
            set: { if !$0 { runnerPendingRemoval = nil } }
        )) {
            Button("Cancel", role: .cancel) { runnerPendingRemoval = nil }
            Button("Remove", role: .destructive) {
                guard let runner = runnerPendingRemoval else { return }
                runnerPendingRemoval = nil
                removeErrorMessage = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = RunnerLifecycleService.shared.stop(runner: runner)
                    DispatchQueue.main.async {
                        if !ok { removeErrorMessage = "Stop failed — the runner may still appear in GitHub." }
                        localRunnerStore.refresh()
                    }
                }
            }
        } message: {
            Text("This will stop the runner service. It may still appear in GitHub until deregistered.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                    Text("Settings").font(.headline)
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Local Runners

    private var localRunnersSection: some View {
        // Explicit [RunnerModel] type annotation prevents Swift from resolving
        // ForEach to the Range<Int> overload when RunnerModel.id is an Int.
        // ❌ NEVER remove the type annotation on localRunners.
        let localRunners: [RunnerModel] = localRunnerStore.runners
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local runners").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: { showAddRunnerSheet = true }) {
                    Image(systemName: "plus").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain).help("Add a new runner").padding(.trailing, 4)
                if localRunnerStore.isScanning {
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                } else {
                    Button(action: { removeErrorMessage = nil; localRunnerStore.refresh() }) {
                        Image(systemName: "arrow.clockwise").font(.caption).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain).help("Refresh local runner list")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if let errMsg = removeErrorMessage {
                Text(errMsg).font(.caption).foregroundColor(.red)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.red.opacity(0.07))
            }

            if localRunners.isEmpty && !localRunnerStore.isScanning && hasLoadedOnce {
                Text("No local runners found").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(localRunners) { runner in localRunnerRow(runner) }
            }
        }
    }

    private func localRunnerRow(_ runner: RunnerModel) -> some View {
        HStack(spacing: 6) {
            Circle().fill(localRunnerDotColor(for: runner)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.runnerName).font(.system(size: 13)).lineLimit(1)
                if let url = runner.gitHubUrl {
                    Text(url).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(runner.displayStatus).font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
            if runner.isRunning {
                Button(action: { lifecycleAction { RunnerLifecycleService.shared.stop(runner: runner) } }) {
                    Text("Stop").font(.caption2)
                }.buttonStyle(.bordered).help("Stop runner service")
            } else {
                Button(action: { lifecycleAction { RunnerLifecycleService.shared.start(runner: runner) } }) {
                    Text("Resume").font(.caption2)
                }.buttonStyle(.bordered).help("Start runner service")
            }
            Button(action: { runnerPendingRemoval = runner }) {
                Image(systemName: "minus.circle").font(.caption2).foregroundColor(.red)
            }.buttonStyle(.plain).help("Remove runner")
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
        case .busy:    return .yellow
        case .idle:    return .gray
        case .offline: return .red
        }
    }

    // MARK: - Runner Management

    private var runnerSection: some View {
        // Explicit [Runner] type annotation is required.
        // Without it, Swift 6 resolves ForEach(runners) to ForEach(Range<Int>)
        // because Runner.id: Int satisfies ExpressibleByIntegerLiteral on Range.
        // ❌ NEVER remove the explicit [Runner] annotation on this local.
        // ❌ NEVER pass observable.runners directly to ForEach.
        let runners: [Runner] = observable.runners
        return VStack(alignment: .leading, spacing: 0) {
            Text("Runner management").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            if runners.isEmpty {
                Text("No runners configured").font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(runners) { runner in
                    HStack(spacing: 8) {
                        Circle().fill(runnerDotColor(for: runner)).frame(width: 8, height: 8)
                        Text(runner.name).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(runner.displayStatus)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                }
            }
            Text("Scopes").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(scopeStore.scopes, id: \.self) { scopeStr in
                HStack {
                    Text(scopeStr).font(.system(size: 12))
                    Spacer()
                    Button(action: { scopeStore.remove(scopeStr); observable.reload() }) {
                        Image(systemName: "minus.circle").foregroundColor(.red)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 2)
            }
            HStack {
                TextField("owner/repo or org", text: $newScope)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit { submitScope() }
                Button(action: submitScope) { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain)
                    .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Notify on success").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $notifications.notifyOnSuccess).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            HStack {
                Text("Notify on failure").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $notifications.notifyOnFailure).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Launch at login").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $settings.launchAtLogin).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            HStack {
                Text("Show offline runners").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $settings.showOfflineRunners).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            Text("When enabled, runners that are offline or unreachable are shown dimmed in the list.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 6)
            Divider().padding(.leading, 12)
            HStack {
                Text("Polling interval").font(.system(size: 12))
                Spacer()
                Text("\(Int(settings.pollingInterval))s")
                    .font(.system(size: 12)).foregroundColor(.secondary).frame(minWidth: 36, alignment: .trailing)
                Stepper("", value: $settings.pollingInterval, in: 10...300).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            Text("How often RunnerBar checks GitHub for runner and workflow status. Lower values use more API quota.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account").font(.caption).foregroundColor(.secondary)
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
                            Text("Sign out").font(.caption).foregroundColor(.red)
                        }
                        .buttonStyle(.plain).disabled(isSigningOut)
                        .help("Run gh auth logout and disconnect RunnerBar from GitHub")
                    }
                } else {
                    Button(action: signInWithGitHub) {
                        Text("Sign in").font(.caption).foregroundColor(.orange)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().padding(.leading, 12)
            Text("Run `gh auth login` in Terminal, or set GH_TOKEN / GITHUB_TOKEN env var.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    // MARK: - Legal

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Legal").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Accept terms").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $legal.hasAcceptedTerms).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("About").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            HStack {
                Text("Version").font(.system(size: 12))
                Spacer()
                Text("\(appVersion) (\(appBuild))").font(.system(size: 12)).foregroundColor(.secondary)
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
        scopeStore.add(trimmed)
        observable.reload()
        newScope = ""
    }

    private func runnerDotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }

    private func signInWithGitHub() {
        guard let url = URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens") else { return }
        NSWorkspace.shared.open(url)
    }

    private func signOutOfGitHub() {
        guard !isSigningOut else { return }
        isSigningOut = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = shell("/opt/homebrew/bin/gh auth logout --hostname github.com")
            DispatchQueue.main.async { isSigningOut = false }
        }
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
