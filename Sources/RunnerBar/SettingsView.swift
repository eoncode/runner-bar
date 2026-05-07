import SwiftUI

// MARK: - SettingsView

/// Phase 0 placeholder — Settings view shell.
/// Phase 1 will add persistence and real content sections.
/// Phase 2 will add runner management (migrated from PopoverMainView).
/// ❌ Do NOT add runner management here until Phase 1 shell is verified.
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

            // ── Placeholder body — Phase 1 will replace this.
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings coming soon")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.top, 16)
                Text("Runner management, notifications, and app preferences will be available here in upcoming phases.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }
            Spacer(minLength: 40)
        }
        // ⚠️ REGRESSION GUARD: keep idealWidth: 420 — matches PopoverMainView (ref #52 #54 #57)
        .frame(idealWidth: 420, maxWidth: .infinity, alignment: .top)
    }
}
