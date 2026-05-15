import SwiftUI

// MARK: - BranchTagPill
/// Phase 6 (Issue #421): Small pill that displays a repo slug or branch name
/// inside the group-title block of `ActionDetailView`.
///
/// Design:
/// - Background: `.ultraThinMaterial` + subtle `rowBackground` tint overlay.
/// - Border: hairline `rowBorder` stroke (adaptive light/dark).
/// - Font: `RBFont.monoLabel` (10 pt, monospaced, semibold).
///
/// ❌ NEVER replace `.ultraThinMaterial` with a flat `.opacity()` fill —
///    spec requires material blending (Issue #421 Phase 6).
struct BranchTagPill: View {
    /// The text to display inside the pill (e.g. `"owner/repo"` or a branch name).
    let name: String

    var body: some View {
        Text(name)
            .font(RBFont.monoLabel)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, DesignTokens.Spacing.chipHPad)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(DesignTokens.Colors.rowBackground)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)
                    )
            )
    }
}
