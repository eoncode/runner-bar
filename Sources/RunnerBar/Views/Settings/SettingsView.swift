// SettingsView.swift
// RunnerBar
// swiftlint:disable orphaned_doc_comment missing_docs
import Combine
import RunnerBarCore
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

// swiftlint:disable:next type_body_length
/// A value type representing SettingsView.
struct SettingsView: View {
    /// The onBack constant.
    let onBack: () -> Void
    /// The store property.
    @ObservedObject var store: RunnerViewModel
    /// The settings property.
    @ObservedObject private var settings = AppPreferencesStore.shared
    /// The notifications property.
    @ObservedObject private var notifications = NotificationPreferences.shared
    /// The localRunnerStore property.
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared
    /// The scopeStore property.
    @ObservedObject private var scopeStore = ScopeStore.shared
    /// The launchAtLogin property.
    @State private var launchAtLogin = LoginItem.isEnabled
    /// The isOAuthAuthenticated property.
    @State private var isOAuthAuthenticated = (Keychain.token != nil)
    /// The isCLIAuthenticated property.
    @State private var isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
    /// The isSigningIn property.
    @State private var isSigningIn = false
    /// The hasLoadedOnce property.
    @State private var hasLoadedOnce = false
    /// The runnerPendingRemoval property.
    @State private var runnerPendingRemoval: RunnerModel?
    /// The showAddRunnerSheet property.
    @State private var showAddRunnerSheet = false
    /// The showAddScopeSheet property.
    @State private var showAddScopeSheet = false
    /// #992: The scope entry currently being edited; non-nil while ScopeEditSheet is presented.
    @State private var selectedScopeEntry: ScopeEntry?
    /// The removeErrorMessage property.
    @State private var removeErrorMessage: String?
    /// Retains the Combine subscription for ScopeStore.didMutate.
    @State private var scopeMutateCancellable: AnyCancellable?
    /// Retains the Combine subscription for OAuthService.didSignOut.
    @State private var signOutCancellable: AnyCancellable?

    // MARK: - Popover editing state (#1001)
    /// The runner currently being edited in `RunnerDetailPopover`. `nil` = popover dismissed.
    @State private var editingRunner: RunnerModel?
    /// `true` while `commitRunnerEdit` is in-flight.
    @State private var isCommitting = false
    /// Non-nil when the last commit attempt produced errors; forwarded into `RunnerDetailPopover`.
    @State private var commitError: String?

    /// The appVersion property.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    /// The appBuild property.
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    /// The removalAlertTitle property.
    private var removalAlertTitle: String {
        "Remove runner \"\(runnerPendingRemoval?.runnerName ?? "this runner\"")"
    }

    /// The body property.
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
        .onChange(of: localRunnerStore.isScanning) { _, newVal in if !newVal { hasLoadedOnce = true } }
        .sheet(isPresented: $showAddRunnerSheet, content: addRunnerSheet)
        .sheet(isPresented: $showAddScopeSheet) { AddScopeSheet(isPresented: $showAddScopeSheet) }
        .sheet(item: $selectedScopeEntry) { entry in
            // #992: ScopeEditSheet replaces the old nav drill-down.
            ScopeEditSheet(
                scopeEntry: entry,
                isPresented: Binding(
                    get: { selectedScopeEntry != nil },
                    set: { if !$0 { selectedScopeEntry = nil } }
                )
            )
        }
        .modifier(removalAlertModifier)
        // #1001: runner editing — use .popover to avoid rectangular corners on the parent panel
        // (.sheet creates a detached child NSWindow whose chrome fights the .borderless panel)
        .popover(item: $editingRunner) { runner in
            runnerEditingPopover(runner: runner)
        }
    }

    // MARK: - Runner editing popover (#1001)

    /// Builds the `RunnerDetailPopover` with commit/cancel wiring.
    @ViewBuilder
    private func runnerEditingPopover(runner: RunnerModel) -> some View {
        RunnerDetailPopover(
            runner: runner,
            commitError: commitError,
            onCommit: { draft in
                guard !isCommitting else { return }
                isCommitting = true
                commitError = nil
                // Build original from disk so the dirty-check in commitRunnerEdit
                // compares against actual persisted values, not model defaults.
                // (#1001 fix: was RunnerEditDraft(runner: runner) which left
                // autoUpdate=true and proxy fields empty regardless of disk state.)
                var original = RunnerEditDraft(runner: runner)
                if let installPath = runner.installPath {
                    original.load(installPath: installPath)
                }
                commitRunnerEdit(runner: runner, draft: draft, original: original) { @MainActor result in
                    isCommitting = false
                    switch result {
                    case .success:
                        localRunnerStore.refresh()
                        editingRunner = nil
                    case .failure(let msgs):
                        commitError = msgs.joined(separator: "\n")
                    }
                }
            },
            onCancel: {
                commitError = nil
                editingRunner = nil
            }
        )
    }

    /// Performs the addRunnerSheet operation.
    private func addRunnerSheet() -> some View {
        AddRunnerSheet(isPresented: $showAddRunnerSheet) { localRunnerStore.refresh() }
    }
    /// The removalAlertModifier property.
    private var removalAlertModifier: RemovalAlertModifier {
        RemovalAlertModifier(
            title: removalAlertTitle,
            isPresented: Binding(
                get: { runnerPendingRemoval != nil },
                set: { if !$0 { runnerPendingRemoval = nil } }
            ),
            isAuthenticated: isOAuthAuthenticated || isCLIAuthenticated,
            onCancel: { runnerPendingRemoval = nil },
            onConfirm: performRemoval
        )
    }

    /// The sectionsStack property.
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
            aboutSection
        }
        .padding(.bottom, 16)
    }

    /// Performs the onAppearAction operation.
    private func onAppearAction() {
        isOAuthAuthenticated = (Keychain.token != nil)
        isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
        OAuthService.shared.onCompletion = { success in
            isOAuthAuthenticated = success
            isCLIAuthenticated = !success && githubToken() != nil
            isSigningIn = false
        }
        signOutCancellable = OAuthService.shared.didSignOut
            .receive(on: DispatchQueue.main)
            .sink {
                isOAuthAuthenticated = false
                isCLIAuthenticated = githubToken() != nil
            }
        scopeMutateCancellable = ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak store] in store?.reload() }
        localRunnerStore.refresh()
    }

    // MARK: - Header
    /// The headerBar property.
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
    /// The localRunnersSectionHeader property.
    private var localRunnersSectionHeader: some View {
        HStack {
            Text("Active local runners")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            Spacer()
            Button(action: { showAddRunnerSheet = true }, label: {
                Image(systemName: "plus").font(.caption).foregroundColor(Color.rbTextSecondary)
            })
            .buttonStyle(.plain)
            .help("Add a new runner")
            .accessibilityIdentifier("addRunnerButton")
            .padding(.trailing, 4)
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

    /// The localRunnersSection property.
    private var localRunnersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            localRunnersSectionHeader
            Text("Self-hosted runners installed on this machine, discovered via LaunchAgent plists.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
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

    /// Performs the localRunnerRow operation.
    private func localRunnerRow(_ runner: RunnerModel) -> some View {
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        Button(action: {
            commitError = nil
            editingRunner = runner
        }) {
            localRunnerRowContent(runner)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
        .glassCard(cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.xs)
    }

    /// Performs the localRunnerRowContent operation.
    private func localRunnerRowContent(_ runner: RunnerModel) -> some View {
        let hasWarning = runner.lifecycleWarning != nil
        let displayStatus = runner.displayStatus
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
            Toggle("", isOn: Binding(
                get: { runner.isRunning },
                set: { isOn in
                    if isOn {
                        performResume(runner: runner)
                    } else {
                        performStop(runner: runner)
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(Color.rbSuccess)
            .labelsHidden()
            .help(runner.isRunning ? "Stop runner service" : "Start runner service")
            .scaleEffect(0.8, anchor: .trailing)
            .buttonStyle(.borderless)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(Color.rbTextTertiary)
            Button(action: { runnerPendingRemoval = runner },
                   label: { Image(systemName: "minus.circle").font(.caption2).foregroundColor(Color.rbDanger) })
            .buttonStyle(.plain).help("Remove runner")
        }
    }

    // MARK: - Resume / Stop actions

    /// Performs the performResume operation.
    private func performResume(runner: RunnerModel) {
        log("SettingsView > performResume called runner=\(runner.runnerName)")
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.start(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                case .corruptInstall:
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ corrupt install")
                case .failed(let msg):
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
                    let short = msg.components(separatedBy: "\n")
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? msg
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ \(short)")
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    /// Performs the performStop operation.
    private func performStop(runner: RunnerModel) {
        log("SettingsView > performStop called runner=\(runner.runnerName)")
        LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = RunnerLifecycleService.shared.stop(runner: runner)
            DispatchQueue.main.async {
                switch result {
                case .success: break
                case .corruptInstall:
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ corrupt install")
                case .failed(let msg):
                    LocalRunnerStore.shared.optimisticallySetRunning(runner.runnerName, isRunning: true)
                    let short = msg.components(separatedBy: "\n")
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? msg
                    LocalRunnerStore.shared.setLifecycleWarning(runner.runnerName, warning: "⚠ \(short)")
                }
                LocalRunnerStore.shared.refresh()
            }
        }
    }

    /// Performs the localRunnerDotColor operation.
    private func localRunnerDotColor(for runner: RunnerModel) -> Color {
        switch runner.statusColor {
        case .running: return Color.rbSuccess
        case .busy:    return Color.rbWarning
        case .idle:    return Color.rbTextTertiary
        case .offline: return Color.rbDanger
        }
    }

    // MARK: - Remote runner scopes

    /// The remoteScopesSectionHeader property.
    private var remoteScopesSectionHeader: some View {
        HStack {
            Text("Remote runner scopes")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            Spacer()
            // swiftlint:disable:next multiple_closures_with_trailing_closure
            Button(action: { showAddScopeSheet = true }) {
                Image(systemName: "plus").font(.caption).foregroundColor(Color.rbTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Add a remote scope")
            .accessibilityIdentifier("addScopeButton")
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 2)
    }

    /// The remoteScopesSection property.
    private var remoteScopesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            remoteScopesSectionHeader
            Text("GitHub repos or orgs whose runners are fetched via the API.")
                .font(.caption).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.bottom, 6)
            if scopeStore.entries.isEmpty {
                Text("No remote scopes added")
                    .font(.caption).foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, RBSpacing.md).padding(.vertical, 4)
            } else {
                ForEach(scopeStore.entries) { entry in
                    scopeRow(entry)
                }
            }
        }
    }

    /// Performs the scopeRow operation.
    private func scopeRow(_ entry: ScopeEntry) -> some View {
        let isRepo = entry.scope.contains("/")
        let displayName = ScopePreferencesStore.displayName(for: entry.scope)
        // swiftlint:disable:next multiple_closures_with_trailing_closure
        return Button(action: { selectedScopeEntry = entry }) {
            HStack(spacing: 8) {
                Text(isRepo ? "Repo" : "Org")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.rbSurfaceElevated))
                    .overlay(Capsule().strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if ScopePreferencesStore.alias(for: entry.scope) != nil {
                        Text(entry.scope)
                            .font(.caption2)
                            .foregroundColor(Color.rbTextTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                Spacer()

                Text(entry.isEnabled ? "Active" : "Paused")
                    .font(.caption2)
                    .foregroundColor(entry.isEnabled ? Color.rbSuccess : Color.rbTextTertiary)

                Toggle("", isOn: Binding(
                    get: { entry.isEnabled },
                    set: { ScopeStore.shared.setEnabled(entry.id, $0); RunnerStore.shared.start() }
                ))
                .toggleStyle(.switch)
                .tint(Color.rbSuccess)
                .labelsHidden()
                .help(entry.isEnabled ? "Pause monitoring" : "Resume monitoring")
                .scaleEffect(0.8, anchor: .trailing)
                .buttonStyle(.borderless)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)

                // swiftlint:disable:next multiple_closures_with_trailing_closure
                Button(action: {
                    ScopePreferencesStore.cleanUp(scope: entry.scope)
                    ScopeStore.shared.remove(id: entry.id)
                    RunnerStore.shared.start()
                }) {
                    Image(systemName: "minus.circle")
                        .font(.caption2)
                        .foregroundColor(Color.rbDanger)
                }
                .buttonStyle(.borderless)
                .help("Remove scope")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 5)
        .glassCard(cornerRadius: RBRadius.small)
        .padding(.horizontal, RBSpacing.xs)
        .opacity(entry.isEnabled ? 1.0 : 0.5)
    }

    // MARK: - Notifications
    /// The notificationsSection property.
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Notify on success").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $notifications.notifyOnSuccess)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
            Divider().padding(.leading, RBSpacing.md)
            HStack {
                Text("Notify on failure").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $notifications.notifyOnFailure)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
        }
    }

    // MARK: - General
    /// The generalSection property.
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Launch at login").font(.system(size: 12)); Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
                    .onChange(of: launchAtLogin) { _, newVal in applyLaunchAtLogin(newVal) }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 6)
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
    /// The accountSection property.
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack(alignment: .center) {
                Text("GitHub").font(.system(size: 12))
                Spacer()
                if isSigningIn {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Waiting for browser…").font(.caption).foregroundColor(Color.rbTextSecondary)
                    }
                } else if isOAuthAuthenticated {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.rbSuccess).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Authenticated")
                                    .font(.caption)
                                    .foregroundColor(Color.rbTextSecondary)
                                Text("via OAuth")
                                    .font(.caption2)
                                    .foregroundColor(Color.rbTextTertiary)
                            }
                        }
                        Button(action: signOutOfGitHub) {
                            Text("Sign out").font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.rbDanger)
                        .help("Remove OAuth token from Keychain. GH_TOKEN / GITHUB_TOKEN env vars used as fallback if available.")
                    }
                } else if isCLIAuthenticated {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.rbSuccess).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Authenticated")
                                    .font(.caption)
                                    .foregroundColor(Color.rbTextSecondary)
                                Text("via env token")
                                    .font(.caption2)
                                    .foregroundColor(Color.rbTextTertiary)
                            }
                        }
                        Button(action: signInWithGitHub) {
                            Text("Sign in with GitHub").font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .help("Authorize RunnerBar via GitHub OAuth and store token in Keychain")
                    }
                } else {
                    Button(action: signInWithGitHub) {
                        Text("Sign in with GitHub").font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .help("Authorize RunnerBar via GitHub OAuth and store token in Keychain")
                }
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 8)
        }
    }

    // MARK: - About
    /// The aboutSection property.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("About").font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 4)
            HStack {
                Text("Version").font(.system(size: 12)); Spacer()
                Text("\(appVersion) (\(appBuild))").font(.system(size: 12)).foregroundColor(Color.rbTextSecondary)
            }
            .padding(.horizontal, RBSpacing.md).padding(.vertical, 5)
        }
    }

    // MARK: - Helpers
    /// Performs the applyLaunchAtLogin operation.
    private func applyLaunchAtLogin(_ enabled: Bool) { LoginItem.setEnabled(enabled) }

    /// Performs the signInWithGitHub operation.
    private func signInWithGitHub() {
        isSigningIn = true
        OAuthService.shared.signIn()
    }

    /// Performs the signOutOfGitHub operation.
    private func signOutOfGitHub() {
        OAuthService.shared.signOut()
    }

    /// Performs the performRemoval operation.
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
// swiftlint:enable orphaned_doc_comment missing_docs
