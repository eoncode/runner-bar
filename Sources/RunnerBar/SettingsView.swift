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
/// ⚠️ REGRESSION GUARD (NSPanel architecture — ref #52 #54 #57 #377):
///
///   ARCHITECTURE: NSPanel + sizingOptions=.preferredContentSize.
///   AppDelegate KVO-observes preferredContentSize and calls NSPanel.setFrame().
///   NSPanel.setFrame() has no anchor → zero side jump.
///
///   ROOT FRAME RULE:
///   .frame(idealWidth: 480)
///   Only idealWidth is needed. No idealHeight. NSPanel handles screen bounds.
///
///   SCROLLVIEW HEIGHT CAP:
///   The ScrollView has .frame(maxHeight: cappedHeight) to prevent the panel
///   from growing taller than 85% of the screen when Settings is very long.
///   This is a screen safety cap — not a fixed height.
///   ❌ NEVER remove .frame(maxHeight: cappedHeight) from the ScrollView.
///   ❌ NEVER increase cappedHeight factor above 0.85.
///
///   WHY ScrollView STILL NEEDS A CAP HERE:
///   ScrollView reports idealHeight = full unbounded content height.
///   Without capping, the ScrollView would make preferredContentSize.height
///   equal to ALL Settings content (~800pt). The panel would be taller than
///   the screen. cappedHeight caps this at screen-safe height.
///
///   ❌ NEVER remove idealWidth: 480 from the root frame.
///   ❌ NEVER add idealHeight to the root frame — NSPanel handles positioning.
///
///   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
///   UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
///   is major major major.
struct SettingsView: View {
    let onBack: () -> Void
    @ObservedObject var store: RunnerStoreObservable

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @ObservedObject private var legal = LegalPrefsStore.shared
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    @State private var hasLoadedOnce = false
    @State private var runnerPendingRemoval: RunnerModel?
    @State private var runnerBeingConfigured: RunnerModel?
    @State private var showAddRunnerSheet = false
    @State private var removeErrorMessage: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "\u{2014}"
    }

    private var removalAlertTitle: String {
        let name = runnerPendingRemoval?.runnerName ?? "this runner"
        return "Remove runner \"\(name)\""
    }

    /// Screen-safe height cap for the Settings ScrollView.
    /// 80% of visible screen height — keeps Settings within screen bounds.
    /// ❌ NEVER increase above 0.85.
    /// ❌ NEVER apply as a fixed .frame(height:).
    private var cappedHeight: CGFloat {
        NSScreen.main.map { $0.visibleFrame.height * 0.80 } ?? 640
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            // ⚠️ ScrollView height cap — screen safety under NSPanel architecture.
            // Prevents the panel from growing beyond the screen height.
            // ❌ NEVER remove .frame(maxHeight: cappedHeight).
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
            // UNDER ANY CIRCUMSTANCE.
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
            .frame(maxHeight: cappedHeight)
        }
        // Only idealWidth needed — no idealHeight under NSPanel architecture.
        // ❌ NEVER add idealHeight here.
        // ❌ NEVER remove idealWidth: 480.
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            hasLoadedOnce = true
        }
        .sheet(isPresented: $showAddRunnerSheet) {
            AddRunnerSheet(isPresented: $showAddRunnerSheet) {
                LocalRunnerStore.shared.refresh()
            }
        }
        .sheet(item: $runnerBeingConfigured) { runner in
            RunnerConfigSheet(runner: runner, isPresented: $runnerBeingConfigured) {
                LocalRunnerStore.shared.refresh()
            }
        }
        .alert(removalAlertTitle, isPresented: Binding(
            get: { runnerPendingRemoval != nil },
            set: { if !$0 { runnerPendingRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) { confirmRemoveRunner() }
            Button("Cancel", role: .cancel) { runnerPendingRemoval = nil }
        } message: {
            if let msg = removeErrorMessage {
                Text(msg)
            } else {
                Text("This will remove the runner from GitHub. This cannot be undone.")
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Local runners section

    private var localRunnersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local runners")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Spacer()
                HStack(spacing: 4) {
                    Button(action: { showAddRunnerSheet = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    Button(action: { Task { await MainActor.run { LocalRunnerStore.shared.refresh() } } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12)
            }
            if localRunnerStore.runners.isEmpty {
                Text("No local runners configured")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
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
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let url = runner.gitHubUrl {
                    Text(url)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(runner.displayStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
            if runner.isRunning {
                Button("Stop") {
                    lifecycleAction { RunnerLifecycleService.shared.stop(runner: runner) }
                }
                .buttonStyle(.bordered)
                .font(.caption2)
                .help("Stop runner service")
            } else {
                Button("Resume") {
                    lifecycleAction { RunnerLifecycleService.shared.start(runner: runner) }
                }
                .buttonStyle(.bordered)
                .font(.caption2)
                .help("Start runner service")
            }
            Button(action: { runnerBeingConfigured = runner }) {
                Image(systemName: "gearshape").font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Configure runner")
            Button(action: { runnerPendingRemoval = runner }) {
                Image(systemName: "minus.circle")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Remove runner")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func localRunnerDotColor(for runner: RunnerModel) -> Color {
        switch runner.statusColor {
        case .running: return .green
        case .busy: return .yellow
        case .idle: return .gray
        case .offline: return .red
        }
    }

    private func lifecycleAction(_ action: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            action()
            DispatchQueue.main.async { LocalRunnerStore.shared.refresh() }
        }
    }

    // MARK: - Runner management section

    private var runnerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Runner management")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            ForEach(store.runners) { runner in
                HStack(spacing: 8) {
                    Circle()
                        .fill(runner.status != "online" ? Color.gray : (runner.busy ? Color.yellow : Color.green))
                        .frame(width: 8, height: 8)
                    Text(runner.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Text(runner.busy ? "busy" : (runner.status == "online" ? "online" : "offline"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Button(action: { runnerPendingRemoval = RunnerModel(
                        runnerName: runner.name,
                        gitHubUrl: nil,
                        agentId: nil,
                        workFolder: nil,
                        installPath: nil,
                        isRunning: false
                    )}) {
                        Image(systemName: "minus.circle")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove runner")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            if store.runners.isEmpty {
                Text("No runners configured")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            scopeRow
        }
    }

    private var scopeRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ScopeStore.shared.scopes, id: \.self) { scope in
                HStack {
                    Text(scope)
                        .font(.system(size: 12))
                    Spacer()
                    Button(action: {
                        ScopeStore.shared.remove(scope)
                        store.reload()
                    }) {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }
            HStack(spacing: 6) {
                TextField("owner/repo or org", text: $newScope)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .onSubmit { addScope() }
                if !newScope.isEmpty {
                    Button("Add") { addScope() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.trailing, 12)
                }
            }
        }
    }

    // MARK: - Notifications section

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Toggle("Notify on success", isOn: $notifications.notifyOnSuccess)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            Toggle("Notify on failure", isOn: $notifications.notifyOnFailure)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    // MARK: - General section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .onChange(of: launchAtLogin) { val in
                    LoginItem.setEnabled(val)
                }
            // showDimmedRunners is the actual property — showOfflineRunners does not exist.
            Toggle("Show offline runners", isOn: $settings.showDimmedRunners)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            pollingIntervalRow
        }
    }

    private var pollingIntervalRow: some View {
        HStack {
            Text("Polling interval")
                .font(.system(size: 13))
            Spacer()
            Text("\(settings.pollingInterval)s")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Stepper("", value: $settings.pollingInterval, in: 10...300, step: 10)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Account section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            if isAuthenticated {
                HStack {
                    Text("GitHub")
                        .font(.system(size: 13))
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Authenticated")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                Text("`gh auth login` in Terminal, or set GH_TOKEN / GITHUB_TOKEN env var.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            } else {
                Button("Connect GitHub account") {
                    let url = URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens")!
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                Text("Run `gh auth login` in Terminal, or set GH_TOKEN / GITHUB_TOKEN env var.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Legal section
    // LegalPrefsStore exposes only `analyticsEnabled` — acceptedTerms/acceptedPrivacy do not exist.

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Legal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Toggle("Share analytics", isOn: $legal.analyticsEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    // MARK: - About section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            HStack {
                Text("Version")
                    .font(.system(size: 13))
                Spacer()
                Text("\(appVersion) (\(appBuild))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            HStack {
                Text("RunnerBar")
                    .font(.system(size: 13))
                Spacer()
                Text(Bundle.main.bundleIdentifier ?? "dev.eonist.runnerbar")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Button("View on GitHub") {
                let url = URL(string: "https://github.com/eoncode/runner-bar")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func addScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        newScope = ""
        store.reload()
    }

    private func confirmRemoveRunner() {
        guard let runner = runnerPendingRemoval else { return }
        removeErrorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let succeeded = RunnerLifecycleService.shared.remove(runner: runner)
            DispatchQueue.main.async {
                if !succeeded {
                    removeErrorMessage = "De-registration failed — the runner may still appear in GitHub. Check your token and try again."
                } else {
                    store.reload()
                    LocalRunnerStore.shared.refresh()
                }
                runnerPendingRemoval = nil
            }
        }
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
