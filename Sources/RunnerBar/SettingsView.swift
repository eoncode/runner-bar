import ServiceManagement
import SwiftUI

// MARK: - SettingsView
// Settings view — complete implementation for all phases 1-6.
//
// HEIGHT CONTRACT:
// headerBar is OUTSIDE the ScrollView — back button always visible.
// ScrollView uses maxHeight: .infinity to fill all remaining panel space.
// AppDelegate.resizeAndRepositionPanel() clamps the panel at 85% visibleFrame.
// No extra cap needed here — the panel cap IS the scroll boundary.
// ❌ NEVER move headerBar inside the ScrollView.
// ❌ NEVER replace .infinity with a fixed number.
// ❌ NEVER use GeometryReader for the height.
// ❌ NEVER add idealHeight to the root frame.
//
// WIDTH CONTRACT:
// .frame(idealWidth: 480) — only idealWidth needed. NSPanel handles bounds.
// ❌ NEVER remove idealWidth: 480.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

// MARK: - URI Constants
private enum SettingsURIs {
    static let privacyPolicy  = "https://dev.eon.st/runnerbar/privacy"
    static let termsOfService = "https://dev.eon.st/runnerbar/terms"
    static let gitHubOAuth    = "https://github.com/login/oauth/authorize"
}

// swiftlint:disable:next type_body_length
struct SettingsView: View {
    let onBack: () -> Void
    @ObservedObject var store: RunnerStoreObservable
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @ObservedObject private var legal = LegalPrefsStore.shared
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared
    @StateObject private var scopeStore = ScopeStore.shared
    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    @State private var hasLoadedOnce = false
    @State private var runnerPendingRemoval: RunnerModel?
    @State private var runnerBeingConfigured: RunnerModel?
    @State private var showAddRunnerSheet = false
    @State private var removeErrorMessage: String?
    @State private var isSigningOut = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    private var removalAlertTitle: String {
        "Remove runner \"\(runnerPendingRemoval?.runnerName ?? "this runner\"")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            // maxHeight: .infinity — fills all space the panel gives us.
            // AppDelegate caps the panel at 85% visibleFrame. That IS the limit.
            // ❌ NEVER move headerBar inside this ScrollView.
            // ❌ NEVER replace .infinity with a fixed number.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
            // UNDER ANY CIRCUMSTANCE.
            ScrollView(.vertical, showsIndicators: true) {
                sectionsStack
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
        .onAppear(perform: onAppearAction)
        .onChange(of: localRunnerStore.isScanning) { if !$0 { hasLoadedOnce = true } }
        .onDisappear { ScopeStore.shared.onMutate = nil }
        .sheet(isPresented: $showAddRunnerSheet, content: addRunnerSheet)
        .sheet(item: $runnerBeingConfigured, content: configSheet)
        .modifier(removalAlertModifier)
    }

    private func addRunnerSheet() -> some View {
        AddRunnerSheet(isPresented: $showAddRunnerSheet) { localRunnerStore.refresh() }
    }
    private func configSheet(_ runner: RunnerModel) -> some View {
        RunnerConfigSheet(runner: runner, isPresented: $runnerBeingConfigured) {
            localRunnerStore.refresh()
        }
    }
    private var removalAlertModifier: RemovalAlertModifier {
        RemovalAlertModifier(
            title: removalAlertTitle,
            isPresented: Binding(
                get: { runnerPendingRemoval != nil },
                set: { if !$0 { runnerPendingRemoval = nil } }
            ),
            isAuthenticated: isAuthenticated,
            onCancel: { runnerPendingRemoval = nil },
            onConfirm: performRemoval
        )
    }

    private var sectionsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            localRunnersSection
            Divider()
            remoteScopesSection
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

    private func onAppearAction() {
        isAuthenticated = (githubToken() != nil)
        ScopeStore.shared.onMutate = { [weak store] in store?.reload() }
        localRunnerStore.refresh()
    }

    // MARK: - Header
    private var headerBar: some View {
        HStack {
            Button(action: onBack, label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Settings").font(.headline)
                }
                .foregroundColor(.primary)
            })
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Local Runners
    private var localRunnersSectionHeader: some View {
        HStack {
            Text("Local runners")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            Spacer()
            Button(action: { showAddRunnerSheet = true }, label: {
                Image(systemName: "plus").font(.caption).foregroundColor(Color.rbTextSecondary)
            })
            .buttonStyle(.plain).help("Add a new runner").padding(.trailing, 4)
            if localRunnerStore.isScanning {
                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
            } else {
                Button(action: { removeErrorMessage = nil; localRunnerStore.refresh() }, label: {
                    Image(systemName: "arrow.clockwise").font(.caption).foregroundColor(Color.rbTextSecondary)
                })
                .buttonStyle(.plain).help("Refresh local runner list")
            }
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
    }

    private var localRunnersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            localRunnersSectionHeader
            if let errMsg = removeErrorMessage {
                Text(errMsg).font(.caption).foregroundColor(Color.rbDanger)
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
                    .background(Color.rbDanger.opacity(0.07))
            }
            if localRunnerStore.runners.isEmpty && !localRunnerStore.isScanning && hasLoadedOnce {
                Text("No local runners found").font(.caption).foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
            } else {
                ForEach(localRunnerStore.runners) { runner in localRunnerRow(runner) }
            }
        }
    }

    private func localRunnerRow(_ runner: RunnerModel) -> some View {
        localRunnerRowContent(runner)
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: RBRadius.small)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.small)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))
                    .padding(.horizontal, RBSpacing.xs)
            )
    }

    private func localRunnerRowContent(_ runner: RunnerModel) -> some View {
        let hasWarning = runner.lifecycleWarning != nil
        let displayStatus = runner.displayStatus
        let statusColor = runner.statusColor
        log("SettingsView > localRunnerRowContent rendering runner=\(runner.runnerName) isRunning=\(runner.isRunning) githubStatus=\(runner.githubStatus ?? "none") lifecycleWarning=\(runner.lifecycleWarning ?? "none") displayStatus=\(displayStatus) statusColor=\(statusColor) hasWarning=\(hasWarning)")
        return HStack(spacing: 6) {
            Circle().fill(localRunnerDotColor(for: runner)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.runnerName).font(.system(size: 13)).lineLimit(1)
                if let url = runner.gitHubUrl {
                    Text(url).font(.caption2).foregroundColor(Color.rbTextSecondary).lineLimit(1)
                }
            }
            Spacer()
            Text(displayStatus)
                .font(.caption)
                .foregroundColor(hasWarning ? Color.rbWarning : Color.rbTextSecondary)
                .lineLimit(1)
                .fixedSize()
            if runner.isRunning {
                Button(action: { performStop(runner: runner) },
                       label: { Text("Stop").font(.caption2) })
                .buttonStyle(.bordered).help("Stop runner service")
            } else {
                Button(action: { performResume(runner: runner) },
                       label: { Text("Resume").font(.caption2) })
                .buttonStyle(.bordered).help("Start runner service")
            }
            Button(action: { runnerBeingConfigured = runner },
                   label: { Image(systemName: "gearshape").font(.caption2) })
            .buttonStyle(.plain).help("Configure runner")
            Button(action: { runnerPendingRemoval = runner },
                   label: { Image(systemName: "minus.circle").font(.caption2).foregroundColor(Color.rbDanger) })
            .buttonStyle(.plain).help("Remove runner")
        }
    }

    // MARK: - Resume / Stop actions

    private func performResume(runner: RunnerModel) {
        log("SettingsView > performResume called runner=\(runner.runnerName) isRunning=\(runner.isRunning) lifecycleWarning=\(runner.lifecycleWarning ?? "none")")
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
        log("SettingsView > performResume — optimistic flip done, dispatching to background")
        DispatchQueue.global(qos: .userInitiated).async {
            log("SettingsView > performResume background — calling RunnerLifecycleService.start for \(runner.runnerName)")
            let result = RunnerLifecycleService.shared.start(runner: runner)
            log("SettingsView > performResume background — start() returned \(result) for \(runner.runnerName)")
            DispatchQueue.main.async {
                log("SettingsView > performResume main — handling result=\(result) for \(runner.runnerName)")
                switch result {
                case .success:
                    log("SettingsView > performResume main — SUCCESS, keeping optimistic flip for \(runner.runnerName)")
                case .corruptInstall:
                    log("SettingsView > performResume main — CORRUPT INSTALL: reverting isRunning and setting warning for \(runner.runnerName)")
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ corrupt install")
                case .failed(let msg):
                    log("SettingsView > performResume main — FAILED (\(msg)): reverting isRunning and setting warning for \(runner.runnerName)")
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                    let shortMsg = msg.components(separatedBy: "\n")
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? msg
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ \(shortMsg)")
                }
                log("SettingsView > performResume main — calling refresh() for \(runner.runnerName)")
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    private func performStop(runner: RunnerModel) {
        log("SettingsView > performStop called runner=\(runner.runnerName) isRunning=\(runner.isRunning) lifecycleWarning=\(runner.lifecycleWarning ?? "none")")
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
        DispatchQueue.global(qos: .userInitiated).async {
            log("SettingsView > performStop background — calling RunnerLifecycleService.stop for \(runner.runnerName)")
            let result = RunnerLifecycleService.shared.stop(runner: runner)
            log("SettingsView > performStop background — stop() returned \(result) for \(runner.runnerName)")
            DispatchQueue.main.async {
                log("SettingsView > performStop main — handling result=\(result) for \(runner.runnerName)")
                switch result {
                case .success:
                    log("SettingsView > performStop main — SUCCESS for \(runner.runnerName)")
                case .corruptInstall:
                    log("SettingsView > performStop main — CORRUPT INSTALL on stop for \(runner.runnerName)")
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ corrupt install")
                case .failed(let msg):
                    log("SettingsView > performStop main — FAILED (\(msg)), reverting for \(runner.runnerName)")
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
                    let shortMsg = msg.components(separatedBy: "\n")
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? msg
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ \(shortMsg)")
                }
                log("SettingsView > performStop main — calling refresh()")
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    private func localRunnerDotColor(for runner: RunnerModel) -> Color {
        let sc = runner.statusColor
        let w = runner.lifecycleWarning ?? "none"
        log("SettingsView > localRunnerDotColor runner=\(runner.runnerName) statusColor=\(sc) lifecycleWarning=\(w) isRunning=\(runner.isRunning) githubStatus=\(runner.githubStatus ?? "none")")
        switch sc {
        case .running: return Color.rbSuccess
        case .busy:    return Color.rbWarning
        case .idle:    return Color.rbTextTertiary
        case .offline: return Color.rbDanger
        }
    }

    // MARK: - Remote runner scopes

    private var remoteScopesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remote runner scopes")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 2)
            Text("GitHub repos or orgs whose runners are fetched via the API.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
            ForEach(scopeStore.scopes, id: \.self) { scopeStr in
                HStack {
                    Text(scopeStr).font(.system(size: 12))
                    Spacer()
                    Button(action: { ScopeStore.shared.remove(scopeStr); RunnerStore.shared.start() },
                           label: { Image(systemName: "minus.circle").foregroundColor(Color.rbDanger) })
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 2)
            }
            HStack {
                TextField("e.g. myorg  or  myorg/myrepo", text: $newScope)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12)).onSubmit { submitScope() }
                Button(action: submitScope, label: { Image(systemName: "plus.circle") })
                    .buttonStyle(.plain)
                    .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
        }
    }

    // MARK: - Notifications
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Notify on success").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $notifications.notifyOnSuccess).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            Divider().padding(.leading, RBSpacing.md)
            HStack {
                Text("Notify on failure").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $notifications.notifyOnFailure).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
        }
    }

    // MARK: - General
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Launch at login").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                    .onChange(of: launchAtLogin, perform: applyLaunchAtLogin)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            Divider().padding(.leading, RBSpacing.md)
            HStack {
                Text("Show offline runners").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $settings.showDimmedRunners).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 2)
            Text("When enabled, runners that are offline or unreachable are shown dimmed in the list.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
            Divider().padding(.leading, RBSpacing.md)
            HStack {
                Text("Polling interval").font(.system(size: 12)); Spacer()
                Text("\(settings.pollingInterval)s").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper("", value: $settings.pollingInterval, in: 10...300).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 2)
            Text("How often RunnerBar checks GitHub for runner and workflow status. Lower values use more API quota.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
        }
    }

    // MARK: - Account
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("GitHub").font(.system(size: 12)); Spacer()
                if isAuthenticated {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.rbSuccess).frame(width: 8, height: 8)
                            Text("Authenticated").font(.caption).foregroundColor(Color.rbTextSecondary)
                        }
                        Button(action: signOutOfGitHub) {
                            Text("Sign out").font(.caption).foregroundColor(Color.rbDanger)
                        }
                        .buttonStyle(.plain).disabled(isSigningOut)
                        .help("Run gh auth logout and disconnect RunnerBar from GitHub")
                    }
                } else {
                    Button(action: signInWithGitHub) {
                        Text("Sign in").font(.caption).foregroundColor(Color.rbWarning)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
            Divider().padding(.leading, RBSpacing.md)
            Text("Run `gh auth login` in Terminal, or set GH_TOKEN / GITHUB_TOKEN env var.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
        }
    }

    // MARK: - Legal
    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Legal").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Share analytics").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $legal.analyticsEnabled).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            #if DEBUG
            Divider().padding(.leading, RBSpacing.md)
            linkRow(label: "Privacy Policy", url: SettingsURIs.privacyPolicy)
            Divider().padding(.leading, RBSpacing.md)
            linkRow(label: "Terms of Service", url: SettingsURIs.termsOfService)
            #endif
        }
    }

    // MARK: - About
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Version").font(.system(size: 12)); Spacer()
                Text("\(appVersion) (\(appBuild))").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
            Divider().padding(.leading, RBSpacing.md)
            HStack {
                Text("RunnerBar").font(.system(size: 12)); Spacer()
                Text("dev.eon.st/runnerbar").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
            Text("A macOS menu bar utility for monitoring GitHub Actions self-hosted runners.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
        }
    }

    // MARK: - Helpers
    private func linkRow(label: String, url: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)); Spacer()
            Link(url, destination: URL(string: url)!)
                .font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
        }
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
    }

    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        newScope = ""
    }

    private func applyLaunchAtLogin(_ enabled: Bool) { LoginItem.setEnabled(enabled) }

    private func signInWithGitHub() {
        guard let url = URL(string: SettingsURIs.gitHubOAuth) else { return }
        NSWorkspace.shared.open(url)
    }

    private func signOutOfGitHub() {
        isSigningOut = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = shell("/opt/homebrew/bin/gh auth logout --hostname github.com")
            DispatchQueue.main.async { isAuthenticated = false; isSigningOut = false }
        }
    }

    private func performRemoval() {
        guard let runner = runnerPendingRemoval else { return }
        runnerPendingRemoval = nil
        LocalRunnerStore.shared.optimisticallyRemove(runner.runnerName)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = RunnerLifecycleService.shared.remove(runner: runner)
            DispatchQueue.main.async {
                if !ok { removeErrorMessage = "Failed to remove \"\(runner.runnerName)\". Check logs." }
                LocalRunnerStore.shared.refresh()
            }
        }
    }
}
