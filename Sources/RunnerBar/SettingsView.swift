// swiftlint:disable file_length
import ServiceManagement
import SwiftUI

// Issue #419 Phase 5 (settings styling): tokenized settings polish is tracked here.

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
    // MARK: - Environment / State
    @EnvironmentObject var localRunnerStore: LocalRunnerStore
    @EnvironmentObject var runnerStore: RunnerStoreObservable
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var legalPrefsStore: LegalPrefsStore
    @EnvironmentObject var notificationPrefsStore: NotificationPrefsStore
    @EnvironmentObject var scopeStore: ScopeStore

    var isAuthenticated: Bool
    var onSignOut: (() -> Void)?
    var onSignIn: (() -> Void)?

    @State private var isSigningOut = false
    @State private var newScope = ""
    @State private var runnerPendingRemoval: RunnerModel?
    @State private var removeErrorMessage: String?
    @State private var hasLoadedOnce = false
    @State private var isAddingRunner = false
    @State private var runnerPendingConfig: RunnerModel?
    @State private var isShowingLegal = false

    var body: some View {
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
        .frame(idealWidth: 320, maxWidth: .infinity, alignment: .top)
        .onAppear { hasLoadedOnce = true }
        .sheet(isPresented: $isAddingRunner) {
            AddRunnerSheet { model in
                localRunnerStore.add(model)
                isAddingRunner = false
            } onCancel: {
                isAddingRunner = false
            }
        }
        .sheet(item: $runnerPendingConfig) { runner in
            RunnerConfigSheet(runner: runner) { updated in
                localRunnerStore.update(updated)
                runnerPendingConfig = nil
            } onCancel: {
                runnerPendingConfig = nil
            }
        }
        .sheet(isPresented: $isShowingLegal) {
            LegalPrefsView(legalPrefsStore: legalPrefsStore)
        }
    }

    // MARK: - Local Runners
    @ViewBuilder private var localRunnersSection: some View {
        SectionHeaderLabel(title: "Local Runners")
        Button(action: { isAddingRunner = true }) {
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
                Text("Scanning…").font(.caption).foregroundColor(.secondary)
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
                Button("Remove") {
                    localRunnerStore.remove(runner)
                    runnerPendingRemoval = nil
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
            Button(action: { runnerPendingConfig = runner }, label: {
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

    /// Local runner status dot — Issue #419 Phase 5: uses DesignTokens instead of raw system colors.
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
        let store = runnerStore.store
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
                Button(action: signInWithGitHub, label: {
                    // Issue #419 Phase 5: use rbWarning instead of .orange
                    Text("Sign in").font(.caption).foregroundColor(.rbWarning)
                }).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Preferences
    @ViewBuilder private var preferencesSection: some View {
        SectionHeaderLabel(title: "Preferences")
        // ── Show offline runners ───────────────────────────────────────────────────────────
        HStack {
            Text("Show offline runners").font(.system(size: 12))
            Spacer()
            Toggle("", isOn: $settingsStore.showOfflineRunners)
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        Text("Offline runners are dimmed when hidden.")
            .font(.caption).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.bottom, 6)
        Divider().padding(.leading, 12)
        // ── Polling interval ────────────────────────────────────────────────────────────────────────────
        HStack {
            Text("Polling interval").font(.system(size: 12))
            Spacer()
            Picker("", selection: $settingsStore.pollingInterval) {
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
        // ── Launch at login ──────────────────────────────────────────────────────────────
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
        let s = newScope.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        ScopeStore.shared.add(s)
        RunnerStore.shared.start()
        newScope = ""
    }

    /// API runner status dot — Issue #419 Phase 5: uses DesignTokens instead of raw system colors.
    private func runnerDotColor(for runner: Runner) -> Color {
        if runner.status != "online" { return .secondary }
        return runner.busy ? .rbBlue : .rbSuccess
    }

    private func linkRow(label: String, url: String) -> some View {
        Button(action: {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
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

    private func signOutOfGitHub() {
        isSigningOut = true
        DispatchQueue.global(qos: .userInitiated).async {
            onSignOut?()
            DispatchQueue.main.async { isSigningOut = false }
        }
    }

    private func signInWithGitHub() {
        onSignIn?()
    }
}
