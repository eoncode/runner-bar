import SwiftUI

// MARK: - Card Row Modifier

/// Applies the standard elevated card row background with a subtle border.
/// The optional `status` tint composites *beneath* the elevated surface so the
/// very-faint status colour shows through on light and dark appearances.
struct CardRowModifier: ViewModifier {
    var status: RBStatus = .unknown
    var cornerRadius: CGFloat = RBRadius.card

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        // ZStack-style composite: tint first, elevated surface on top.
                        // rbSurfaceElevated is semi-transparent, so tint bleeds through.
                        AnyShapeStyle(
                            ZStack {
                                Color.rbSurfaceElevated
                                status.tint
                            }
                            .compositingGroup()
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func cardRow(status: RBStatus = .unknown, cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(CardRowModifier(status: status, cornerRadius: cornerRadius))
    }
}

// MARK: - Pill Background Modifier

/// Applies a pill-shaped semi-transparent background — used for disk badge, stat pills, branch tags.
struct PillBackgroundModifier: ViewModifier {
    var color: Color
    var opacity: Double = 0.15
    var borderOpacity: Double = 0.35

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

extension View {
    func pillBackground(color: Color, opacity: Double = 0.15, borderOpacity: Double = 0.35) -> some View {
        modifier(PillBackgroundModifier(color: color, opacity: opacity, borderOpacity: borderOpacity))
    }
}

// MARK: - Mono Label Modifier

/// Applies monospaced font and secondary text color — used for hashes, timestamps, step counts.
struct MonoLabelModifier: ViewModifier {
    var size: Font = RBFont.mono
    var color: Color = .rbTextTertiary

    func body(content: Content) -> some View {
        content
            .font(size)
            .foregroundStyle(color)
    }
}

extension View {
    func monoLabel(font: Font = RBFont.mono, color: Color = .rbTextTertiary) -> some View {
        modifier(MonoLabelModifier(size: font, color: color))
    }
}

// MARK: - Left Status Indicator

/// The narrow left-side colored bar used to group and indicate status for action rows.
struct LeftStatusIndicator: View {
    var status: RBStatus
    var width: CGFloat = 3
    var cornerRadius: CGFloat = RBRadius.indicator

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(status.color)
            .frame(width: width)
    }
}

// MARK: - Stat Pill

/// Small pill-shaped background for runner CPU/MEM inline stats.
struct StatPill: View {
    let label: String
    let value: String

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

struct BranchTagPill: View {
    let name: String

    var body: some View {
        Text(name)
            .font(RBFont.monoSmall)
            .foregroundStyle(Color.rbBlue)
            .pillBackground(color: .rbBlue, opacity: 0.12, borderOpacity: 0.0)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: RBStatus
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(status.color)
            .pillBackground(color: status.color, opacity: 0.18, borderOpacity: 0.0)
    }
}
