// SettingsView.swift
// RunnerBar
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

/// Root settings view. Navigation rows lead to `LocalRunnersView` and `ScopesView`.
/// See HEIGHT/WIDTH CONTRACT comments above before making layout changes.
struct SettingsView: View {
    // MARK: - Inputs
    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void
    // periphery:ignore - injected by caller for @ObservedObject subscription; read indirectly via passed closures
    /// The shared runner view-model; observed for remote runner list updates.
    @ObservedObject var store: RunnerViewModel

    // MARK: - Observed stores
    // @StateObject — NOT @ObservedObject — because these are singleton instances
    // assigned inline. @ObservedObject re-creates its subscription wrapper on every
    // render cycle; when the singleton publishes a change SwiftUI re-renders, tears
    // down the wrapper, re-subscribes, and can fire objectWillChange again before the
    // render settles → infinite glitchy loop. @StateObject is owned by SwiftUI for the
    // lifetime of this view's identity, so the subscription is stable.
    // store (RunnerViewModel) is injected by the caller and must stay @ObservedObject.
    //
    // NOTE: These properties (and the @State vars below) are `internal` rather than
    // `private` so that SettingsView+Sections.swift can access them from a separate-file
    // extension. Swift does not allow `private` members to be read across files even
    // within the same type. See SE-0169. signOutCancellable is the sole exception —
    // it is not referenced in the extension and intentionally stays `private`.
    /// App-wide preferences (notifications, update channel, etc.).
    @StateObject var settings = AppPreferencesStore.shared
    /// Notification opt-in preferences per scope.
    @StateObject var notifications = NotificationPreferences.shared

    // MARK: - Local UI state
    /// Mirrors `LoginItem.isEnabled`; toggled by the Launch at Login switch.
    @State var launchAtLogin = LoginItem.isEnabled
    /// `true` when a valid OAuth token is stored in Keychain.
    @State var isOAuthAuthenticated = (Keychain.token != nil)
    /// `true` when a CLI token (GH_TOKEN / GITHUB_TOKEN) is present but no OAuth token.
    @State var isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
    /// `true` while the OAuth sign-in flow is in progress.
    @State var isSigningIn = false
    // FIXME: AnyCancellable stored in @State risks silent subscription drop if SwiftUI
    // recreates the view struct and reallocates @State storage. The correct pattern
    // (used by RunnerViewModel) is to hold cancellables as stored properties on a
    // @MainActor class. Tracked for refactor alongside #1077. // NOSONAR
    /// Retains the sign-out Combine subscription.
    @State private var signOutCancellable: AnyCancellable?
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
    /// Root view: swaps between the settings scroll, `LocalRunnersView`, and `ScopesView`.
    var body: some View {
        // Lifecycle modifiers live on the root (wrapping all branches) so
        // onAppearAction()/onDisappear fire only when the settings panel itself
        // opens/closes — NOT on every navigation to LocalRunnersView/ScopesView.
        // Attaching them to `settingsBody` caused needless Keychain re-reads and
        // signOutCancellable recreation on every back-navigation.
        Group {
            if showLocalRunners {
                LocalRunnersView(
                    onBack: { showLocalRunners = false },
                    isAuthenticated: isOAuthAuthenticated || isCLIAuthenticated
                )
            } else if showScopes {
                ScopesView(onBack: { showScopes = false })
            } else {
                settingsBody
            }
        }
        .onAppear(perform: onAppearAction)
        .onDisappear {
            // Clear the singleton closure so a future SettingsView instance can claim it.
            // Without this, the last-opened instance permanently owns onCompletion.
            // Guard: do not clear while an OAuth flow is in progress — the callback must land.
            if !isSigningIn { OAuthService.shared.onCompletion = nil }
        }
    }

    /// The main settings layout (header + sections scroll).
    ///
    /// Extracted from `body` so `LocalRunnersView` and `ScopesView` can replace it cleanly
    /// without any structural duplication.
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
    }

    /// Vertical stack of all settings sections.
    ///
    /// Order: Account → Management → General → About
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

    /// Runs on `.onAppear`: refreshes auth state and starts the sign-out listener.
    private func onAppearAction() {
        let keychainToken = Keychain.token
        let envToken = githubToken()
        isOAuthAuthenticated = (keychainToken != nil)
        isCLIAuthenticated = (keychainToken == nil && envToken != nil)
        log("SettingsView › onAppear — Keychain.token=\(keychainToken != nil ? "present(len=\(keychainToken!.count))" : "nil") githubToken=\(envToken != nil ? "present(len=\(envToken!.count))" : "nil") isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
        OAuthService.shared.onCompletion = { success in
            log("SettingsView › onCompletion — success=\(success), updating auth state")
            isOAuthAuthenticated = success
            isCLIAuthenticated = !success && githubToken() != nil
            log("SettingsView › onCompletion — isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
            isSigningIn = false
        }
        signOutCancellable = OAuthService.shared.didSignOut
            .receive(on: DispatchQueue.main)
            .sink {
                let postToken = githubToken()
                log("SettingsView › didSignOut sink — githubToken post-signout=\(postToken != nil ? "present(len=\(postToken!.count))" : "nil")")
                isOAuthAuthenticated = false
                isCLIAuthenticated = postToken != nil
                log("SettingsView › didSignOut sink — isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
            }
    }

    // MARK: - Header
    /// Top bar with back button and "Settings" title.
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
    /// Applies or removes the Login Item entry based on `enabled`.
    func applyLaunchAtLogin(_ enabled: Bool) { LoginItem.setEnabled(enabled) }

    /// Initiates the OAuth sign-in flow via `OAuthService`.
    func signInWithGitHub() {
        log("SettingsView › signInWithGitHub — isSigningIn=true")
        isSigningIn = true
        OAuthService.shared.signIn()
    }

    /// Signs out of GitHub and clears all stored tokens.
    func signOutOfGitHub() {
        log("SettingsView › signOutOfGitHub — calling OAuthService.shared.signOut()")
        OAuthService.shared.signOut()
    }
}
