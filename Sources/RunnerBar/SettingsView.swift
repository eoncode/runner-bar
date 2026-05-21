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
enum SettingsURIs {
    static let privacyPolicy  = "https://dev.eon.st/runnerbar/privacy"
    static let termsOfService = "https://dev.eon.st/runnerbar/terms"
}

// swiftlint:disable:next type_body_length
struct SettingsView: View {
    let onBack: () -> Void
    let onSelectRunner: (RunnerModel) -> Void
    let onSelectScope: (ScopeEntry) -> Void
    @ObservedObject var store: RunnerStoreObservable
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @ObservedObject private var legal = LegalPrefsStore.shared
    @ObservedObject private var localRunnerStore = LocalRunnerStore.shared
    @ObservedObject private var scopeStore = ScopeStore.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State var isOAuthAuthenticated = (Keychain.token != nil)
    @State var isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
    @State var isSigningIn = false
    @State var hasLoadedOnce = false
    @State var runnerPendingRemoval: RunnerModel?
    @State var showAddRunnerSheet = false
    @State var showAddScopeSheet = false
    @State var removeErrorMessage: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    var removalAlertTitle: String {
        "Remove runner \"\(runnerPendingRemoval?.runnerName ?? "this runner\"")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
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
        .sheet(isPresented: $showAddScopeSheet) { AddScopeSheet(isPresented: $showAddScopeSheet) }
        .modifier(removalAlertModifier)
    }

    func addRunnerSheet() -> some View {
        AddRunnerSheet(isPresented: $showAddRunnerSheet) { localRunnerStore.refresh() }
    }

    var removalAlertModifier: RemovalAlertModifier {
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

    func onAppearAction() {
        isOAuthAuthenticated = (Keychain.token != nil)
        isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
        OAuthService.shared.onCompletion = { success in
            isOAuthAuthenticated = success
            isCLIAuthenticated = !success && githubToken() != nil
            isSigningIn = false
        }
        ScopeStore.shared.onMutate = { [weak store] in store?.reload() }
        localRunnerStore.refresh()
    }

    func applyLaunchAtLogin(_ enabled: Bool) { LoginItem.setEnabled(enabled) }

    func signInWithGitHub() {
        isSigningIn = true
        OAuthService.shared.signIn()
    }

    func signOutOfGitHub() {
        OAuthService.shared.signOut()
    }

    func performRemoval() {
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

    func performResume(runner: RunnerModel) {
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

    func performStop(runner: RunnerModel) {
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
}
