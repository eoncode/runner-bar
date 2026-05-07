import ServiceManagement
import SwiftUI

// MARK: - SettingsView

/// Phase 6 — Settings view: General, Scopes, Notifications, App, Account, Legal.
/// All phases of issue #221 are now implemented.
struct SettingsView: View {
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var notifications = NotificationPrefsStore.shared
    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var isAuthenticated = (githubToken() != nil)
    /// Phase 6: analytics opt-out, persisted in UserDefaults (default true).
    @State private var analyticsEnabled: Bool = {
        guard UserDefaults.standard.object(forKey: "legal.analyticsEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "legal.analyticsEnabled")
    }()

    private var appVersion: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(ver) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Back").font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                Spacer()
                Text("Settings").font(.headline).foregroundColor(.primary)
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            Divider()
            // ── Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    settingsSection(title: "General") {
                        toggleRow(label: "Show offline runners", value: $settings.showDimmedRunners)
                        Divider().padding(.leading, 12)
                        stepperRow(
                            label: "Polling interval",
                            value: $settings.pollingInterval,
                            unit: "s",
                            range: 10...300
                        )
                    }
                    settingsSection(title: "Scopes") {
                        ForEach(ScopeStore.shared.scopes, id: \.self) { scope in
                            HStack {
                                Text(scope).font(.system(size: 12))
                                Spacer()
                                Button(
                                    action: {
                                        ScopeStore.shared.remove(scope)
                                        RunnerStore.shared.start()
                                    },
                                    label: {
                                        Image(systemName: "minus.circle").foregroundColor(.red)
                                    }
                                ).buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            Divider().padding(.leading, 12)
                        }
                        HStack {
                            TextField("owner/repo or org", text: $newScope)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onSubmit { submitScope() }
                            Button(action: submitScope) {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(newScope.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    settingsSection(title: "Notifications") {
                        toggleRow(label: "Notify on success", value: $notifications.notifyOnSuccess)
                        Divider().padding(.leading, 12)
                        toggleRow(label: "Notify on failure", value: $notifications.notifyOnFailure)
                    }
                    settingsSection(title: "App") {
                        toggleRow(
                            label: "Launch at login",
                            value: Binding(
                                get: { launchAtLogin },
                                set: { newValue in
                                    launchAtLogin = newValue
                                    LoginItem.setEnabled(newValue)
                                }
                            )
                        )
                        Divider().padding(.leading, 12)
                        HStack {
                            Text("Quit RunnerBar").font(.system(size: 13))
                            Spacer()
                            Button(
                                action: { NSApplication.shared.terminate(nil) },
                                label: { Text("Quit").font(.system(size: 12)).foregroundColor(.red) }
                            ).buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    settingsSection(title: "Account") {
                        HStack {
                            Text("GitHub").font(.system(size: 13))
                            Spacer()
                            if isAuthenticated {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.green).frame(width: 8, height: 8)
                                    Text("Authenticated")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            } else {
                                Button(
                                    action: signInWithGitHub,
                                    label: {
                                        Text("Sign in")
                                            .font(.caption).foregroundColor(.orange)
                                    }
                                ).buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        Divider().padding(.leading, 12)
                        infoRow(label: "Version", value: appVersion)
                    }
                    // ── Legal (Phase 6, ref #221)
                    settingsSection(title: "Legal") {
                        toggleRow(
                            label: "Share analytics",
                            value: Binding(
                                get: { analyticsEnabled },
                                set: { newValue in
                                    analyticsEnabled = newValue
                                    UserDefaults.standard.set(newValue, forKey: "legal.analyticsEnabled")
                                }
                            )
                        )
                        Divider().padding(.leading, 12)
                        linkRow(label: "Privacy Policy", url: "https://github.com/eoncode/runner-bar")
                        Divider().padding(.leading, 12)
                        linkRow(label: "EULA", url: "https://github.com/eoncode/runner-bar")
                    }
                }
                .padding(.bottom, 16)
            }
        }
        // ⚠️ REGRESSION GUARD: keep idealWidth: 420 — matches PopoverMainView (ref #52 #54 #57)
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear { isAuthenticated = (githubToken() != nil) }
    }

    // MARK: - Actions

    private func submitScope() {
        let trimmed = newScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ScopeStore.shared.add(trimmed)
        RunnerStore.shared.start()
        newScope = ""
    }

    private func signInWithGitHub() {
        let script = "tell application \"Terminal\" to do script \"gh auth login\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    // MARK: - Section builder

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 4)
            VStack(spacing: 0) { content() }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .padding(.horizontal, 12)
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func toggleRow(label: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: value).labelsHidden().toggleStyle(.switch)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func stepperRow(
        label: String,
        value: Binding<Int>,
        unit: String,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Text("\(value.wrappedValue)\(unit)")
                .font(.system(size: 13)).foregroundColor(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            Stepper("", value: value, in: range).labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 13)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func linkRow(label: String, url: String) -> some View {
        Button(
            action: {
                if let dest = URL(string: url) { NSWorkspace.shared.open(dest) }
            },
            label: {
                HStack {
                    Text(label).font(.system(size: 13)).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        ).buttonStyle(.plain)
    }
}
