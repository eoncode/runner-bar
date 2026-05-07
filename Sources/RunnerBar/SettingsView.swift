import SwiftUI

// MARK: - SettingsView

/// Phase 1 — Settings view shell with section structure and SettingsStore bindings.
/// Phase 2 will add runner management (migrated from PopoverMainView).
/// ❌ Do NOT add runner management here until Phase 1 shell is verified in production.
struct SettingsView: View {
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void

    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption)
                        Text("Back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                Spacer()
                Text("Settings")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                // Balance the back button width so the title is centred.
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            Divider()
            // ── Content sections
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    settingsSection(title: "General") {
                        toggleRow(
                            label: "Show offline runners",
                            value: $store.showDimmedRunners
                        )
                        Divider().padding(.leading, 12)
                        stepperRow(
                            label: "Polling interval",
                            value: $store.pollingInterval,
                            unit: "s",
                            range: 10...300
                        )
                    }
                    // Phase 2 placeholder: Runner management section added here.
                    // Phase 4 placeholder: Notifications section added here.
                    // Phase 5 placeholder: Account section added here.
                    // Phase 6 placeholder: Legal section added here.
                }
                .padding(.bottom, 16)
            }
        }
        // ⚠️ REGRESSION GUARD: keep idealWidth: 420 — matches PopoverMainView (ref #52 #54 #57)
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
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
            VStack(spacing: 0) {
                content()
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func toggleRow(label: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func stepperRow(
        label: String,
        value: Binding<Int>,
        unit: String,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Text("\(value.wrappedValue)\(unit)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
