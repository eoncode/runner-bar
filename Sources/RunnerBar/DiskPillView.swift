import SwiftUI

// MARK: - DiskPillView
/// Phase 2 (Issue #419): Disk usage pill shown in the popover header alongside CPU/MEM sparklines.
///
/// Design spec:
/// - Background: `.ultraThinMaterial` for adaptive light/dark blending,
///   overlaid with a subtle `pillColor` tint at low opacity.
/// - Fill: `Capsule` stroke driven by `freePct` (green → orange → red threshold).
/// - Label: "DISK" in `monoLabel` font + free-space value in `monoStat`.
///
/// ❌ NEVER replace `.ultraThinMaterial` with a flat `.opacity()` fill —
///    spec requires material blending (Issue #419 review comment, PR #435).
struct DiskPillView: View {
    /// Percentage of disk space that is free (0–100).
    let freePct: Double
    /// Rounded used GB.
    let usedGB: Int
    /// Rounded total GB.
    let totalGB: Int

    private var pillColor: Color {
        // Threshold is on *used* percentage, i.e. 100 - freePct
        DesignTokens.Colors.usage(pct: 100 - freePct)
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("DISK")
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(freeLabel)
                .font(DesignTokens.Fonts.monoStat)
                .foregroundColor(pillColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, DesignTokens.Spacing.chipHPad)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(pillColor.opacity(0.10))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(pillColor.opacity(0.28), lineWidth: 0.75)
                )
        )
    }

    private var freeLabel: String {
        let freeGB = max(0, totalGB - usedGB)
        return "\(freeGB)GB free"
    }
}
