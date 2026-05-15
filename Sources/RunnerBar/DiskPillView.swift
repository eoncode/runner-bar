import SwiftUI

// MARK: - DiskPillView
/// Phase 2: Capsule-backed pill showing disk used/total or free percentage.
/// Color: green → orange → red as free space drops below 30% / 10%.
///
/// Defined here (separate file) so PopoverMainViewSubviews.swift and any
/// future views can reference it without a forward-declaration issue.
///
/// Color thresholds:
///   freePct >= 30  → statusGreen
///   freePct >= 10  → statusOrange
///   freePct <  10  → statusRed
struct DiskPillView: View {
    /// Percentage of disk that is free (0–100).
    let freePct: Double
    /// Used gigabytes (rounded).
    let usedGB: Int
    /// Total gigabytes (rounded).
    let totalGB: Int

    private var pillColor: Color {
        if freePct >= 30 { return DesignTokens.Colors.statusGreen }
        if freePct >= 10 { return DesignTokens.Colors.statusOrange }
        return DesignTokens.Colors.statusRed
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("DISK")
                .font(DesignTokens.Fonts.monoLabel)
                .foregroundColor(.secondary)
            Text("\(usedGB)/\(totalGB)GB")
                .font(DesignTokens.Fonts.monoStat)
                .foregroundColor(pillColor)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(pillColor.opacity(0.12))
                .overlay(
                    Capsule()
                        .strokeBorder(pillColor.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}
