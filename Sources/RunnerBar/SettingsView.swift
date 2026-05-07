import SwiftUI

/// Settings view — complete implementation for all phases 1-6.
///
/// Contains the shared settings UI with runner management, notifications
/// (placeholder, out of scope per AGENTS.md), general toggles,
/// and about section.
struct SettingsView: View {
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void
    /// The observable that bridges RunnerStore state into SwiftUI.
    @ObservedObject var store: RunnerStoreObservable

    @State private var newScope = ""
    @State private var launchAtLogin = LoginItem.isEnabled

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

            // ── Notifications (Phase 4 — out of scope, placeholder)
            VStack(alignment: .leading, spacing: 8) {
                Text("Notifications")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                Text("Not available in this version")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(.horizontal, 12)
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
                    Text("\(appVersion) (\(appBuild))").font(.system(size: 12)).foregroundColor(.secondary)
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
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
        .onAppear {
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
}
