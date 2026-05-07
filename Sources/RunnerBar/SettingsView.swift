import SwiftUI

/// Settings view — complete implementation for all phases 1-6.
///
/// Contains the shared settings UI with runner management, notifications,
/// general toggles, account, legal preferences, and about section.
struct SettingsView: View {
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notificationPrefs = NotificationPrefsStore.shared
    @ObservedObject private var legalPrefs = LegalPrefsStore.shared

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                        Text("Settings")
                            .font(.headline)
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            Divider()

            // ── Runner management (Phase 2)
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
                    Button(action: submitScope) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            Divider()

            // ── Notifications (Phase 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("Notifications")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                Toggle(isOn: $notificationPrefs.notifyOnSuccess) {
                    Text("Notify on success").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider().padding(.leading, 12)
                Toggle(isOn: $notificationPrefs.notifyOnFailure) {
                    Text("Notify on failure").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()

            // ── General (Phase 5)
            VStack(alignment: .leading, spacing: 0) {
                Text("General")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                Toggle(isOn: $launchAtLogin) {
                    Text("Launch at login").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .onChange(of: launchAtLogin) { _, newValue in
                    LoginItem.setEnabled(newValue)
                }
                Divider().padding(.leading, 12)
                Toggle(isOn: $settings.showDimmedRunners) {
                    Text("Show offline runners").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider().padding(.leading, 12)
                HStack {
                    Text("Polling interval").font(.system(size: 12))
                    Spacer()
                    Text("\(settings.pollingInterval)s")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                    Stepper("", value: $settings.pollingInterval, in: 10...300)
                        .labelsHidden()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()

            // ── Account
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
                            Text("Authenticated")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: signInWithGitHub) {
                            Text("Sign in").font(.caption).foregroundColor(.orange)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider().padding(.leading, 12)
                // Auth reads token via: `gh auth token` > GH_TOKEN > GITHUB_TOKEN (see Auth.swift).
                Text("Run `gh auth login` in Terminal, or set GH_TOKEN / GITHUB_TOKEN env var.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()

            // ── Legal
            VStack(alignment: .leading, spacing: 0) {
                Text("Legal")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                Toggle(isOn: $legalPrefs.analyticsEnabled) {
                    Text("Share analytics").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12).padding(.vertical, 6)
#if DEBUG
                // ⚠️ Placeholder URLs — gated behind DEBUG so they never ship to users (ref #245).
                Divider().padding(.leading, 12)
                legalLinkRow(label: "Privacy Policy", urlString: "https://github.com/eoncode/runner-bar")
                Divider().padding(.leading, 12)
                legalLinkRow(label: "EULA", urlString: "https://github.com/eoncode/runner-bar")
#endif
            }
            Divider()

            // ── About (Phase 6)
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
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2)
            }
        }
        // ⚠️ REGRESSION GUARD — do not remove or change idealWidth: 420.
        // Matches PopoverMainView frame contract. Removing this breaks popover sizing (ref #52 #54 #57).
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
            isAuthenticated = (githubToken() != nil)
            ScopeStore.shared.onMutate = { [weak store] in
                store?.reload()
            }
        }
    }

    // MARK: - Helpers

    /// Validates and persists a new scope, triggers polling, reloads the observable, and clears the field.
    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        store.reload()
        newScope = ""
    }

    /// Runner status dot color.
    private func runnerDotColor(for runner: Runner) -> Color {
        runner.status != "online" ? .gray : (runner.busy ? .yellow : .green)
    }

    /// Opens the GitHub PAT setup docs in the default browser.
    /// Device-flow URL omitted: it requires a user_code the app never generates.
    /// Auth.swift reads token via `gh auth token` / GH_TOKEN / GITHUB_TOKEN.
    private func signInWithGitHub() {
        let path = "https://docs.github.com/en/authentication/" +
            "keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// A tappable row that opens a URL in the default browser.
    private func legalLinkRow(label: String, urlString: String) -> some View {
        Button(
            action: {
                if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
            },
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
}
