import SwiftUI

/// Settings shell — Phase 1. Contains the shared settings UI shell
/// that subsequent phases will populate with runner management,
/// notifications, general toggles, and about sections.
struct SettingsView: View {
    /// Called when the user taps the back button to return to the main view.
    let onBack: () -> Void

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

            // ── Placeholder content for future phases
            VStack(alignment: .leading, spacing: 8) {
                Text("Runner management")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                Text("Coming in Phase 2")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Notifications")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                Text("Coming in Phase 4")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("General")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                Text("Coming in Phase 5")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("About")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                Text("Coming in Phase 6")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }
        }
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
    }
}
