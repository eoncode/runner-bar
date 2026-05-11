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
/// ⚠️ REGRESSION GUARD: .frame(idealWidth: 480) MUST match AppDelegate.fixedWidth (480).
/// ❌ NEVER change idealWidth without updating fixedWidth in AppDelegate.
/// ⚠️ SCROLLVIEW RULE (ref #370, main branch JobDetailView):
///    ScrollView MUST have .frame(maxHeight: visibleFrame * 0.75) or equivalent cap.
///    Without it, when Settings is the root at openPopover() time, SwiftUI reports
///    the full unbounded scroll content as fittingSize.height, giving an oversized
///    popover. When navigated to from main (smaller frame), content is clipped.
///    The cap ensures a predictable fittingSize that fills the popover correctly.
/// ❌ NEVER remove the .frame(maxHeight:) from the ScrollView.
/// ❌ NEVER add maxHeight: .infinity to the root VStack — corrupts fittingSize.width.
/// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            // ⚠️ .frame(maxHeight:) is REQUIRED on this ScrollView — do NOT remove.
            // Without it, fittingSize.height is the full unbounded scroll content height
            // when Settings is root at openPopover() time, causing an oversized popover.
            // When navigated to from a shorter frame (main), content is clipped without the cap.
            // Pattern matches main branch's JobDetailView fix for issue #370.
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
            // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
            // is major major major.
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
            // ⚠️ REQUIRED — caps fittingSize.height. Prevents oversized or clipped Settings.
            // Matches main's JobDetailView pattern (issue #370).
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        // ⚠️ REGRESSION GUARD: keep idealWidth: 480 — matches PopoverMainView and AppDelegate.fixedWidth.
        // ❌ NEVER add maxHeight: .infinity here — corrupts fittingSize.width and causes popover side-jump.
        // ❌ NEVER change idealWidth without updating AppDelegate.fixedWidth.
        // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            ScopeStore.shared.onMutate = { [weak store] in
                store?.reload()
            }
            localRunnerStore.refresh()
        }
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
                            removeErrorMessage = "De-registration failed \u{2014} the runner may " +
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

    // #11: Each toggle row uses HStack so label stays leading and toggle stays trailing.
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Notify on success").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $notifications.notifyOnSuccess)
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            HStack {
                Text("Notify on failure").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $notifications.notifyOnFailure)
                    .toggleStyle(.switch).labelsHidden()
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
                    .toggleStyle(.switch).labelsHidden()
                    .onChange(of: launchAtLogin, perform: applyLaunchAtLogin)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            // #23: "Show offline runners" row with subtitle explaining what it does.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show offline runners").font(.system(size: 12))
                    Text("Include runners that are offline or unreachable in the runner list")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.showDimmedRunners)
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().padding(.leading, 12)
            // #12: Polling row with subtitle under the label.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Polling interval").font(.system(size: 12))
                    Text("How often to refresh runner and action status")
                        .font(.caption2).foregroundColor(.secondary)
                }
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
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
#if DEBUG
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

    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
