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

/// Root settings view. Contains all settings sections inside a ScrollView.
/// Local runner management is in `LocalRunnersView`, reached via `manageLocalRunnersRow`.
/// See HEIGHT/WIDTH CONTRACT comments above before making layout changes.
struct SettingsView: View {
    // MARK: - Inputs
    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void
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
    /// App-wide preferences (notifications, update channel, etc.).
    @StateObject private var settings = AppPreferencesStore.shared
    /// Notification opt-in preferences per scope.
    @StateObject private var notifications = NotificationPreferences.shared
    /// Registered remote runner scopes (org / repo URLs).
    @StateObject private var scopeStore = ScopeStore.shared

    // MARK: - Local UI state
    /// Mirrors `LoginItem.isEnabled`; toggled by the Launch at Login switch.
    @State private var launchAtLogin = LoginItem.isEnabled
    /// `true` when a valid OAuth token is stored in Keychain.
    @State private var isOAuthAuthenticated = (Keychain.token != nil)
    /// `true` when a CLI token (GH_TOKEN / GITHUB_TOKEN) is present but no OAuth token.
    @State private var isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
    /// `true` while the OAuth sign-in flow is in progress.
    @State private var isSigningIn = false
    /// Controls presentation of `AddScopeSheet`.
    @State private var showAddScopeSheet = false
    /// #992: The scope entry currently being edited; non-nil while ScopeEditSheet is presented.
    @State private var selectedScopeEntry: ScopeEntry?
    // FIXME: AnyCancellable stored in @State risks silent subscription drop if SwiftUI
    // recreates the view struct and reallocates @State storage. The correct pattern
    // (used by RunnerViewModel) is to hold cancellables as stored properties on a
    // @MainActor class. Tracked for refactor alongside #1077. // NOSONAR
    /// Retains the scope-mutation Combine subscription.
    @State private var scopeMutateCancellable: AnyCancellable?
    /// Retains the sign-out Combine subscription.
    @State private var signOutCancellable: AnyCancellable?
    /// `true` while `LocalRunnersView` is displayed instead of the main settings scroll.
    @State private var showLocalRunners = false

    // MARK: - Computed properties
    /// Short version string from `CFBundleShortVersionString`.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u2014"
    }
    /// Build number from `CFBundleVersion`.
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "\u2014"
    }

    // MARK: - Body
    /// Root view: swaps between the settings scroll and `LocalRunnersView` via `showLocalRunners`.
    var body: some View {
        if showLocalRunners {
            LocalRunnersView(
                onBack: { showLocalRunners = false },
                isAuthenticated: isOAuthAuthenticated || isCLIAuthenticated
            )
        } else {
            settingsBody
        }
    }

    /// The main settings layout (header + sections scroll).
    ///
    /// Extracted from `body` so `LocalRunnersView` can replace it cleanly
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
        .onAppear(perform: onAppearAction)
        .onDisappear {
            // Clear the singleton closure so a future SettingsView instance can claim it.
            // Without this, the last-opened instance permanently owns onCompletion.
            // Guard: do not clear while an OAuth flow is in progress — the callback must land.
            if !isSigningIn { OAuthService.shared.onCompletion = nil }
        }
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
    }

    /// Vertical stack of all settings sections.
    private var sectionsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            manageLocalRunnersRow
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

    /// Runs on `.onAppear`: refreshes auth state and starts the scope-mutation listener.
    private func onAppearAction() {
        let keychainToken = Keychain.token
        let envToken = githubToken()
        isOAuthAuthenticated = (keychainToken != nil)
        isCLIAuthenticated = (keychainToken == nil && envToken != nil)
        log("SettingsView \u203a onAppear \u2014 Keychain.token=\(keychainToken != nil ? "present(len=\(keychainToken!.count))" : "nil") githubToken=\(envToken != nil ? "present(len=\(envToken!.count))" : "nil") isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
        OAuthService.shared.onCompletion = { success in
            log("SettingsView \u203a onCompletion \u2014 success=\(success), updating auth state")
            isOAuthAuthenticated = success
            isCLIAuthenticated = !success && githubToken() != nil
            log("SettingsView \u203a onCompletion \u2014 isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
            isSigningIn = false
        }
        signOutCancellable = OAuthService.shared.didSignOut
            .receive(on: DispatchQueue.main)
            .sink {
                let postToken = githubToken()
                log("SettingsView \u203a didSignOut sink \u2014 githubToken post-signout=\(postToken != nil ? "present(len=\(postToken!.count))" : "nil")")
                isOAuthAuthenticated = false
                isCLIAuthenticated = postToken != nil
                log("SettingsView \u203a didSignOut sink \u2014 isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
            }
        scopeMutateCancellable = ScopeStore.shared.didMutate
            .receive(on: DispatchQueue.main)
            .sink { [weak store] in store?.reload() }
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

    // MARK: - Manage Local Runners

    /// Navigation row that drills into `LocalRunnersView`.
    private var manageLocalRunnersRow: some View {
        Button {
            showLocalRunners = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage local runners").font(.system(size: 12))
                    Text("Start, stop, edit, and remove self-hosted runners on this machine.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Color.rbTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RBSpacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Remote runner scopes
    /// Section header row for the remote scopes list.
    private var remoteScopesSectionHeader: some View {
        HStack {
            Text("Remote runner scopes")
                .font(RBFont.sectionHeader).foregroundColor(Color.rbTextSecondary)
            Spacer()
            Button {
                showAddScopeSheet = true
            } label: {
                Image(systemName: "plus").font(.caption).foregroundColor(Color.rbTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Add a remote scope")
            .accessibilityIdentifier("addScopeButton")
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 8).padding(.bottom, 2)
    }

    /// Scrollable list of registered remote runner scopes.
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

    /// Row view for a single remote scope entry.
    private func scopeRow(_ entry: ScopeEntry) -> some View {
        let isRepo = entry.scope.contains("/")
        let displayName = ScopePreferencesStore.displayName(for: entry.scope)
        return Button {
            selectedScopeEntry = entry
        } label: {
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

                Button {
                    ScopePreferencesStore.cleanUp(scope: entry.scope)
                    ScopeStore.shared.remove(id: entry.id)
                    RunnerStore.shared.start()
                } label: {
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
    /// Notification opt-in toggles for each event type.
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
    /// General section: launch-at-login toggle, polling interval, and popover arrow toggle.
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
            Divider().padding(.leading, RBSpacing.md)
            // #1184: show/hide the NSPopover anchor arrow
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show popover arrow").font(.system(size: 12))
                    Text("Controls whether the anchor arrow is shown on the menu bar popover. Takes effect on next open.")
                        .font(.caption2).foregroundColor(Color.rbTextSecondary)
                }
                Spacer()
                Toggle("", isOn: $settings.showPopoverArrow)
                    .toggleStyle(.switch).tint(Color.rbSuccess).labelsHidden()
            }
            .padding(.horizontal, RBSpacing.md).padding(.top, 6).padding(.bottom, 6)
        }
    }

    // MARK: - Account
    /// GitHub sign-in / sign-out controls and authentication status.
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
                        Text("Waiting for browser\u2026").font(.caption).foregroundColor(Color.rbTextSecondary)
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
    /// App version, build number, and links to changelog / support.
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
    /// Applies or removes the Login Item entry based on `enabled`.
    private func applyLaunchAtLogin(_ enabled: Bool) { LoginItem.setEnabled(enabled) }

    /// Initiates the OAuth sign-in flow via `OAuthService`.
    private func signInWithGitHub() {
        log("SettingsView \u203a signInWithGitHub \u2014 isSigningIn=true")
        isSigningIn = true
        OAuthService.shared.signIn()
    }

    /// Signs out of GitHub and clears all stored tokens.
    private func signOutOfGitHub() {
        log("SettingsView \u203a signOutOfGitHub \u2014 calling OAuthService.shared.signOut()")
        OAuthService.shared.signOut()
    }
}
