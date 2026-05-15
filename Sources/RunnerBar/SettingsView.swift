// swiftlint:disable file_length
import ServiceManagement
import SwiftUI

// Issue #419 Phase 5 (settings styling): tokenized settings polish is tracked here.
//
// ════════════════════════════════════════════════════════════════════════════════
// SCROLLVIEW / LAYOUT CONTRACT — DO NOT CHANGE STRUCTURE
// ════════════════════════════════════════════════════════════════════════════════
// SettingsView is wrapped in ScrollView — this is intentional for Phase 5.
// The outer scroll is required to accommodate variable content height on
// smaller screens. The onBack closure MUST remain as a parameter prop —
// it is wired by AppDelegate and must not be removed or replaced with
// environment routing.
//
// ❌ NEVER remove onBack from the prop list.
// ❌ NEVER replace onBack with an environment-based dismiss mechanism.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
// ALLOWED UNDER ANY CIRCUMSTANCE.
// ════════════════════════════════════════════════════════════════════════════════

// swiftlint:disable type_body_length
// MARK: - SettingsView

/// Settings view — complete implementation for all phases 1-6.
///
/// Section guide:
///   Local Runners — scan, add, remove, configure local runners.
///   GitHub Runners — live status of API runners.
///   Scopes — add/remove watched org / user / repo slugs.
///   Account — GitHub auth status + sign-in / sign-out.
///   Preferences — polling interval, offline-runner visibility, startup.
///   Legal — privacy & legal links.
struct SettingsView: View {
    // MARK: - Props
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable

    // MARK: - Observed stores (singletons, NOT injected props)
    @ObservedObject private var settings         = SettingsStore.shared
    @ObservedObject private var notifications    = NotificationPrefsStore.shared
    @ObservedObject private var legal            = LegalPrefsStore.shared
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared

    // MARK: - Local state
    @State private var newScope              = ""
    @State private var launchAtLogin         = LoginItem.isEnabled
    /// Derived from keychain / env token — NOT injected as a prop.
    @State private var isAuthenticated       = (githubToken() != nil)
    @State private var hasLoadedOnce         = false
    @State private var showAddRunnerSheet    = false
    @State private var removeErrorMessage: String?
    @State private var isSigningOut          = false
    @State private var isShowingLegal        = false
    /// Runner pending remove confirmation — also used as sheet binding for RunnerConfigSheet.
    @State private var runnerPendingRemoval: RunnerModel?
    /// Runner being configured via RunnerConfigSheet; nil = no sheet shown.
    @State private var runnerBeingConfigured: RunnerModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Back").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    localRunnersSection
                    Divider().padding(.leading, 12)
                    githubRunnersSection
                    Divider().padding(.leading, 12)
                    scopesSection
                    Divider().padding(.leading, 12)
                    accountSection
                    Divider().padding(.leading, 12)
                    preferencesSection
                    Divider().padding(.leading, 12)
                    legalSection
                }
            }
        }
        .frame(idealWidth: 320, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            ScopeStore.shared.onMutate = { [weak store] in store?.reload() }
            localRunnerStore.refresh()
        }
        // Single-parameter onChange — macOS 13 compatible.
        .onChange(of: localRunnerStore.isScanning) { scanning in
            if !scanning { hasLoadedOnce = true }
        }
        .onDisappear {
            ScopeStore.shared.onMutate = nil
        }
        .sheet(isPresented: $showAddRunnerSheet) {
            AddRunnerSheet(isPresented: $showAddRunnerSheet, onComplete: {
                Task { @MainActor in localRunnerStore.refresh() }
            })
        }
        .sheet(item: $runnerBeingConfigured) { runner in
            // RunnerConfigSheet manages its own dismiss via isPresented binding.
            // On save, we re-scan so the updated runner name/URL is reflected.
            let binding = Binding<RunnerModel?>(
                get: { runnerBeingConfigured },
                set: { runnerBeingConfigured = $0 }
            )
            RunnerConfigSheet(runner: runner, isPresented: binding, onSave: {
                Task { @MainActor in localRunnerStore.refresh() }
            })
        }
        .sheet(isPresented: $isShowingLegal) {
            LegalPrefsView(legalPrefsStore: legal)
        }
    }

    // MARK: - Local Runners
    @ViewBuilder private var localRunnersSection: some View {
        SectionHeaderLabel(title: "Local Runners")
        Button(action: { showAddRunnerSheet = true }) {
            HStack {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Add runner").font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help("Add a local self-hosted runner")

        if localRunnerStore.isScanning {
            HStack {
                ProgressView().controlSize(.mini)
                Text("Scanning\u{2026}").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }

        if let errMsg = removeErrorMessage {
            Text(errMsg)
                .font(.caption).foregroundColor(.rbDanger)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.rbDanger.opacity(0.07))
        }

        if localRunnerStore.runners.isEmpty && !localRunnerStore.isScanning && hasLoadedOnce {
            Text("No runners added yet.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            ForEach(localRunnerStore.runners) { runner in
                localRunnerRow(runner)
            }
        }

        if let runner = runnerPendingRemoval {
            Text("Remove \"\(runner.runnerName)\"?")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 2)
            HStack {
                Button("Cancel") { runnerPendingRemoval = nil }
                    .font(.caption).buttonStyle(.plain).foregroundColor(.secondary)
                // LocalRunnerStore is a scan-only store with no remove API.
                // Dismissing the confirmation and re-scanning is the correct
                // approach; removal of managed runners is handled by deregistering
                // via the runner's own config.sh --remove command.
                Button("Remove") {
                    runnerPendingRemoval = nil
                    removeErrorMessage = "Remove via the runner directory (config.sh --remove)."
                }
                .font(.caption).buttonStyle(.plain).foregroundColor(.rbDanger)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
        }
    }

    @ViewBuilder private func localRunnerRow(_ runner: RunnerModel) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(localRunnerDotColor(for: runner))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.runnerName)
                    .font(RBFont.mono).lineLimit(1)
                if let url = runner.gitHubUrl {
                    Text(url)
                        .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: { runnerBeingConfigured = runner }, label: {
                Image(systemName: "gear").font(.caption2).foregroundColor(.secondary)
            })
            .buttonStyle(.plain)
            .help("Configure runner")
            Button(action: { runnerPendingRemoval = runner }, label: {
                Image(systemName: "minus.circle").font(.caption2).foregroundColor(.rbDanger)
            })
            .buttonStyle(.plain)
            .help("Remove runner")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    /// Issue #419 Phase 5: uses DesignTokens instead of raw system colors.
    private func localRunnerDotColor(for runner: RunnerModel) -> Color {
        switch runner.statusColor {
        case .running: return .rbSuccess
        case .busy:    return .rbBlue
        case .idle:    return .secondary
        case .offline: return .rbDanger
        }
    }

    // MARK: - GitHub Runners
    @ViewBuilder private var githubRunnersSection: some View {
        SectionHeaderLabel(title: "GitHub Runners")
        ForEach(store.runners, id: \.id) { runner in
            HStack(spacing: 8) {
                Circle().fill(runnerDotColor(for: runner)).frame(width: 8, height: 8)
                Text(runner.name).font(RBFont.mono).lineLimit(1)
                Spacer()
                Text(runner.displayStatus)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
        if store.runners.isEmpty {
            Text("No GitHub runners found.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }

    // MARK: - Scopes
    @ViewBuilder private var scopesSection: some View {
        SectionHeaderLabel(title: "Scopes")
        HStack {
            TextField("org, user, or repo slug", text: $newScope)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { addScope() }
            Button(action: addScope) {
                Image(systemName: "plus.circle").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        ForEach(ScopeStore.shared.scopes, id: \.self) { scopeStr in
            HStack {
                Text(scopeStr).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Button(action: {
                    ScopeStore.shared.remove(scopeStr)
                    RunnerStore.shared.start()
                    store.reload()
                }, label: {
                    Image(systemName: "minus.circle").foregroundColor(.rbDanger)
                }).buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
        }
    }

    // MARK: - Account
    @ViewBuilder private var accountSection: some View {
        SectionHeaderLabel(title: "Account")
        HStack {
            if isAuthenticated {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        // Issue #419 Phase 5: use rbSuccess instead of .green
                        Circle().fill(Color.rbSuccess).frame(width: 8, height: 8)
                        Text("Authenticated").font(.caption).foregroundColor(.secondary)
                    }
                    Button(action: signOutOfGitHub) {
                        Text("Sign out")
                            .font(.caption)
                            // Issue #419 Phase 5: use rbDanger instead of .red
                            .foregroundColor(.rbDanger)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSigningOut)
                    .help("Run gh auth logout and disconnect RunnerBar from GitHub")
                }
            } else {
                Button(action: signInWithGitHub) {
                    // Issue #419 Phase 5: use rbWarning instead of .orange
                    Text("Sign in").font(.caption).foregroundColor(.rbWarning)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        Divider().padding(.leading, 12)
        Text("Run `gh auth login` in Terminal, or set GH_TOKEN / GITHUB_TOKEN env var.")
            .font(.caption).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 4)
    }

    // MARK: - Preferences
    @ViewBuilder private var preferencesSection: some View {
        SectionHeaderLabel(title: "Preferences")
        HStack {
            Text("Show offline runners").font(.system(size: 12))
            Spacer()
            Toggle("", isOn: $settings.showOfflineRunners)
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        Text("Offline runners are dimmed when hidden.")
            .font(.caption).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.bottom, 6)
        Divider().padding(.leading, 12)
        HStack {
            Text("Polling interval").font(.system(size: 12))
            Spacer()
            Picker("", selection: $settings.pollingInterval) {
                Text("15s").tag(15)
                Text("30s").tag(30)
                Text("60s").tag(60)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        Divider().padding(.leading, 12)
        HStack {
            Text("Launch at login").font(.system(size: 12))
            Spacer()
            Toggle("", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Legal
    @ViewBuilder private var legalSection: some View {
        SectionHeaderLabel(title: "Legal")
        Button(action: { isShowingLegal = true }) {
            HStack {
                Text("Privacy & Legal").font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers
    private func addScope() {
        let scope = newScope.trimmingCharacters(in: .whitespaces)
        guard !scope.isEmpty else { return }
        ScopeStore.shared.add(scope)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }

    /// Issue #419 Phase 5: uses DesignTokens instead of raw system colors.
    private func runnerDotColor(for runner: Runner) -> Color {
        if runner.status != "online" { return .secondary }
        return runner.busy ? .rbBlue : .rbSuccess
    }

    private func linkRow(label: String, url: String) -> some View {
        Button(action: {
            if let dest = URL(string: url) { NSWorkspace.shared.open(dest) }
        }) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    /// Runs `gh auth logout --hostname github.com` on a background thread.
    /// ❌ NEVER run shell calls on the main thread.
    private func signOutOfGitHub() {
        guard !isSigningOut else { return }
        isSigningOut = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = shell("/opt/homebrew/bin/gh auth logout --hostname github.com")
            DispatchQueue.main.async {
                isAuthenticated = (githubToken() != nil)
                isSigningOut = false
            }
        }
    }

    private func signInWithGitHub() {
        let urlString = "https://docs.github.com/en/authentication/"
            + "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
