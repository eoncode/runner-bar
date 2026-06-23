// SettingsView.swift
// RunnerBar
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

/// Root settings view. Navigation rows lead to `LocalRunnersView` and `ScopesView`.
/// See HEIGHT/WIDTH CONTRACT comments above before making layout changes.
///
/// No `onRestartPolling` callback is needed — all `ScopeStore` mutations are
/// observed by `RunnerStore`'s `withObservationTracking` loop automatically.
struct SettingsView: View {
    // MARK: - Inputs
    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void
    // periphery:ignore - injected by caller; read indirectly via passed closures
    /// The shared runner view-model; observed for remote runner list updates.
    var store: RunnerViewModel
    /// The local runner actor forwarded into `LocalRunnersView`.
    /// Defaults to `LocalRunnerStore.shared` so call sites that don't own the actor still compile.
    var localRunnerStore: LocalRunnerStore = .shared
    /// OAuth service injected from `AppDelegate`.
    /// Typed to protocol so tests can supply a stub without the live singleton.
    var oauthService: any OAuthServiceProtocol
    /// Runner lifecycle service injected from `AppDelegate` and forwarded into `LocalRunnersView`.
    /// Typed to protocol so tests can supply a stub without spawning real `svc.sh` processes.
    /// No default — callers must supply the `AppDelegate`-owned instance explicitly.
    var lifecycleService: any RunnerLifecycleServiceProtocol

    // MARK: - Observed stores
    /// App-wide preferences (notifications, update channel, etc.).
    @State var settings = AppPreferencesStore.shared
    /// Notification opt-in preferences per scope.
    @State var notifications = NotificationPreferences.shared

    // MARK: - Local UI state
    /// Mirrors `LoginItem.isEnabled`; toggled by the Launch at Login switch.
    @State var launchAtLogin = LoginItem.isEnabled
    /// `true` when a valid OAuth token is stored in Keychain.
    @State var isOAuthAuthenticated = (Keychain.token != nil)
    /// `true` when a CLI token (GH_TOKEN / GITHUB_TOKEN) is present but no OAuth token.
    @State var isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
    /// `true` while the OAuth sign-in flow is in progress.
    @State var isSigningIn = false
    /// Retains the sign-out listener Task so it is cancelled when the view disappears.
    @State private var signOutTask: Task<Void, Never>?
    /// `true` while `LocalRunnersView` is displayed instead of the main settings scroll.
    @State var showLocalRunners = false
    /// `true` while `ScopesView` is displayed instead of the main settings scroll.
    @State var showScopes = false

    // MARK: - Computed properties
    /// Short version string from `CFBundleShortVersionString`.
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    /// Build number from `CFBundleVersion`.
    var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: - Body
    var body: some View {
        Group {
            if showLocalRunners {
                LocalRunnersView(
                    onBack: { showLocalRunners = false },
                    isAuthenticated: isOAuthAuthenticated || isCLIAuthenticated,
                    store: store,
                    localRunnerStore: localRunnerStore,
                    lifecycleService: lifecycleService
                )
            } else if showScopes {
                ScopesView(onBack: { showScopes = false })
            } else {
                settingsBody
            }
        }
        .onAppear(perform: onAppearAction)
        .onDisappear {
            if !isSigningIn { oauthService.onCompletion = nil }
            signOutTask?.cancel()
            signOutTask = nil
        }
    }

    /// The main settings layout (header + sections scroll).
    ///
    /// HEIGHT CONTRACT: headerBar is OUTSIDE the ScrollView — back button always visible.
    /// ❌ NEVER move headerBar inside the ScrollView.
    /// ❌ NEVER replace .infinity with a fixed number.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                sectionsStack
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
    }

    private var sectionsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountSection
            Divider()
            managementSection
            Divider()
            generalSection
            Divider()
            aboutSection
        }
        .padding(.bottom, 16)
    }

    private func onAppearAction() {
        let keychainToken = Keychain.token
        let envToken = githubToken()
        isOAuthAuthenticated = (keychainToken != nil)
        isCLIAuthenticated = (keychainToken == nil && envToken != nil)
        #if DEBUG
        // swiftlint:disable:next line_length
        log("SettingsView › onAppear — Keychain.token=\(keychainToken.map { "present(len=\($0.count))" } ?? "nil") githubToken=\(envToken.map { "present(len=\($0.count))" } ?? "nil") isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
        #endif
        oauthService.onCompletion = { success in
            log("SettingsView › onCompletion — success=\(success), updating auth state")
            isOAuthAuthenticated = success
            isCLIAuthenticated = !success && githubToken() != nil
            isSigningIn = false
        }
        signOutTask = Task { @MainActor in
            for await _ in oauthService.makeSignOutStream() {
                let postToken = githubToken()
                log("SettingsView › didSignOut — githubToken post-signout=\(postToken != nil ? "present(len=\(postToken!.count))" : "nil")")
                isOAuthAuthenticated = false
                isCLIAuthenticated = postToken != nil
            }
        }
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

    // MARK: - Helpers
    func applyLaunchAtLogin(_ enabled: Bool) { LoginItem.setEnabled(enabled) }

    func signInWithGitHub() {
        log("SettingsView › signInWithGitHub — isSigningIn=true")
        isSigningIn = true
        oauthService.signIn()
    }

    func signOutOfGitHub() {
        log("SettingsView › signOutOfGitHub — calling oauthService.signOut()")
        oauthService.signOut()
    }
}
