// swiftlint:disable all
import SwiftUI

/// Root settings view.
struct SettingsView: View {
    let onBack: () -> Void
    @EnvironmentObject var store: RunnerStoreObservable
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var legalPrefs: LegalPrefsStore
    @State private var selectedTab: SettingsTab = .general
    @State private var showLegal: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 400)
        .sheet(isPresented: $showLegal) { LegalPrefsView(legalPrefsStore: legalPrefs) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, selected: selectedTab == tab) { selectedTab = tab }
            }
            Spacer()
            Button("Back") { onBack() }
                .buttonStyle(.plain).font(.caption).foregroundColor(.accentColor)
                .padding(.horizontal, 12).padding(.bottom, 4)
            Button("Privacy & Legal") { showLegal = true }
                .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(width: 160).padding(.top, 12)
    }

    @ViewBuilder private var content: some View {
        switch selectedTab {
        case .general: GeneralSettingsView()
        case .account: AccountSettingsView()
        case .notifications: NotificationSettingsView()
        case .runners: RunnerSettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, account, notifications, runners, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"; case .account: return "Account"
        case .notifications: return "Notifications"; case .runners: return "Runners"
        case .advanced: return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"; case .account: return "person.crop.circle"
        case .notifications: return "bell"; case .runners: return "server.rack"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab; let selected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon).frame(width: 16)
                Text(tab.label); Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(selected ? .accentColor : .primary)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    var body: some View {
        Form {
            Section("Polling") {
                Slider(value: $settingsStore.pollingInterval, in: 10...120, step: 5) {
                    Text("Interval")
                } minimumValueLabel: { Text("10s") } maximumValueLabel: { Text("2m") }
                Text("Every \(Int(settingsStore.pollingInterval))s").font(.caption).foregroundColor(.secondary)
            }
            Section("Runners") {
                Toggle("Show offline runners", isOn: $settingsStore.showOfflineRunners)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $settingsStore.launchAtLogin)
            }
        }.formStyle(.grouped).padding()
    }
}

private struct AccountSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var store: RunnerStoreObservable
    var body: some View {
        Form {
            Section("GitHub") {
                LabeledContent("Organisation / User") {
                    TextField("e.g. my-org", text: $settingsStore.githubOrg).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Personal Access Token") {
                    SecureField("ghp_\u{2026}", text: $settingsStore.githubToken).textFieldStyle(.roundedBorder)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Save & Reconnect") { store.applySettings(settingsStore) }.buttonStyle(.borderedProminent)
                }
            }
        }.formStyle(.grouped).padding()
    }
}

private struct NotificationSettingsView: View {
    var body: some View {
        Form {
            Section("Alerts") {
                Toggle("Notify on job failure", isOn: .constant(true))
                Toggle("Notify on job success", isOn: .constant(false))
            }
        }.formStyle(.grouped).padding()
    }
}

private struct RunnerSettingsView: View {
    @EnvironmentObject var localRunnerStore: LocalRunnerStore
    var body: some View {
        Form {
            Section("Local Runners") {
                if localRunnerStore.isScanning {
                    Text("Scanning…").foregroundColor(.secondary)
                } else if localRunnerStore.runners.isEmpty {
                    Text("No local runners found.").foregroundColor(.secondary)
                } else {
                    let runners = localRunnerStore.runners
                    ForEach(runners) { runner in
                        HStack {
                            Text(runner.name)
                            Spacer()
                            Text(runner.status).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
        .onAppear { localRunnerStore.refresh() }
    }
}

private struct AdvancedSettingsView: View {
    var body: some View {
        Form {
            Section("Debug") {
                Text("Advanced options coming soon.").foregroundColor(.secondary)
            }
        }.formStyle(.grouped).padding()
    }
}
