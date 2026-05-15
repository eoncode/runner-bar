import SwiftUI

// MARK: - Card Row Modifier

/// Applies the standard elevated card row background with a subtle border.
/// The optional `status` tint composites *beneath* the elevated surface so the
/// very-faint status colour shows through on light and dark appearances.
struct CardRowModifier: ViewModifier {
    /// Status tint applied beneath the elevated surface.
    var status: RBStatus = .unknown
    /// Corner radius for the card shape.
    var cornerRadius: CGFloat = RBRadius.card

    /// Wraps `content` with an elevated card background tinted by `status`.
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.rbSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(status.tint)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// View helpers for applying `CardRowModifier`.
extension View {
    /// Applies `CardRowModifier` with the given status tint and corner radius.
    func cardRow(status: RBStatus = .unknown, cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(CardRowModifier(status: status, cornerRadius: cornerRadius))
    }
}

// MARK: - Pill Background Modifier

/// Applies a pill-shaped semi-transparent background — used for disk badge, stat pills, branch tags.
struct PillBackgroundModifier: ViewModifier {
    /// Fill color for the pill.
    var color: Color
    /// Opacity of the pill fill.
    var opacity: Double = 0.15
    /// Opacity of the pill border stroke.
    var borderOpacity: Double = 0.35

    /// Wraps `content` with a capsule fill and optional stroke border.
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, RBSpacing.sm)
            .padding(.vertical, RBSpacing.xxs)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(opacity))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(color.opacity(borderOpacity), lineWidth: 0.75)
                    )
            )
    }
}

/// View helpers for applying `PillBackgroundModifier`.
extension View {
    /// Applies `PillBackgroundModifier` with the given fill color, opacity, and border opacity.
    func pillBackground(
        color: Color,
        opacity: Double = 0.15,
        borderOpacity: Double = 0.35
    ) -> some View {
        modifier(PillBackgroundModifier(color: color, opacity: opacity, borderOpacity: borderOpacity))
    }
}

// MARK: - Mono Label Modifier

/// Applies monospaced font and secondary text color — used for hashes, timestamps, step counts.
struct MonoLabelModifier: ViewModifier {
    /// Font applied to content.
    var size: Font = RBFont.mono
    /// Foreground color applied to content.
    var color: Color = .rbTextTertiary

    /// Applies monospaced font and tertiary color to `content`.
    func body(content: Content) -> some View {
        content
            .font(size)
            .foregroundStyle(color)
    }
}

/// View helpers for applying `MonoLabelModifier`.
extension View {
    /// Applies `MonoLabelModifier` with the given font and color.
    func monoLabel(font: Font = RBFont.mono, color: Color = .rbTextTertiary) -> some View {
        modifier(MonoLabelModifier(size: font, color: color))
    }
}

// MARK: - Left Status Indicator

/// The narrow left-side colored bar used to group and indicate status for action rows.
struct LeftStatusIndicator: View {
    /// Status whose color fills the indicator bar.
    var status: RBStatus
    /// Width of the indicator bar in points.
    var width: CGFloat = 3
    /// Corner radius of the indicator bar.
    var cornerRadius: CGFloat = RBRadius.indicator

    /// Renders a rounded rectangle filled with `status.color`.
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(status.color)
            .frame(width: width)
    }
}

// MARK: - Stat Pill

/// Small pill-shaped background for runner CPU/MEM inline stats.
struct StatPill: View {
    /// Short metric label, e.g. "CPU" or "MEM".
    let label: String
    /// Formatted metric value, e.g. "42%".
    let value: String

    /// Renders the label and value in a pill-shaped card.
    var body: some View {
        HStack(spacing: RBSpacing.xxs) {
            Text(label)
                .font(RBFont.monoSmall)
                .foregroundStyle(Color.rbTextTertiary)
            Text(value)
                .font(RBFont.monoSmall)
                .foregroundStyle(Color.rbTextSecondary)
                .fontWeight(.medium)
        }
        .padding(.horizontal, RBSpacing.xs + 2)
        .padding(.vertical, RBSpacing.xxs + 1)
        .background(
            RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                .fill(Color.rbSurfaceElevated.opacity(1.0))
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Branch Tag Pill

/// A pill-shaped tag displaying a branch name in blue monospaced text.
struct BranchTagPill: View {
    /// The branch name to display.
    let name: String

    /// Renders the branch name in a blue pill.
    var body: some View {
        Text(name)
            .font(RBFont.monoSmall)
            .foregroundStyle(Color.rbBlue)
            .pillBackground(color: .rbBlue, opacity: 0.12, borderOpacity: 0.0)
    }
}

// MARK: - Status Badge

/// A pill-shaped badge displaying a status label in the status’s theme color.
struct StatusBadge: View {
    /// The status whose color tints the badge.
    let status: RBStatus
    /// The text label rendered inside the badge.
    let text: String

    /// Renders `text` in a pill tinted by `status.color`.
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(status.color)
            .pillBackground(color: status.color, opacity: 0.18, borderOpacity: 0.0)
    }
}
