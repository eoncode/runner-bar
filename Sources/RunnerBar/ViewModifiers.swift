import SwiftUI

// MARK: - Card Row Modifier

/// Applies the standard elevated card row background with a subtle border.
/// Layer order (back to front):
///   1. rbSurfaceElevated fill (base elevation)
///   2. status.tint fill overlay (colour signal on top)
///   3. strokeBorder (hairline edge)
struct CardRowModifier: ViewModifier {
    var status: RBStatus = .unknown
    var cornerRadius: CGFloat = RBRadius.card

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
/// Uses .foregroundColor (not .foregroundStyle) for macOS 13 compatibility.
struct MonoLabelModifier: ViewModifier {
    var size: Font = RBFont.mono
    var color: Color = .rbTextTertiary

    func body(content: Content) -> some View {
        content
            .font(size)
            .foregroundColor(color) // macOS 13 compatible
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
/// opacity(1.0) — previously was 1.4 (no-op above 1.0; fixed).
struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: RBSpacing.xxs) {
            Text(label)
                .font(RBFont.monoSmall)
                .foregroundColor(Color.rbTextTertiary) // macOS 13 compatible
            Text(value)
                .font(RBFont.monoSmall)
                .foregroundColor(Color.rbTextSecondary) // macOS 13 compatible
                .fontWeight(.medium)
        }
        .padding(.horizontal, RBSpacing.xs + 2)
        .padding(.vertical, RBSpacing.xxs + 1)
        .background(
            RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                .fill(Color.rbSurfaceElevated.opacity(1.0)) // was 1.4 (no-op); corrected
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
            .foregroundColor(Color.rbBlue) // macOS 13 compatible
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
            .foregroundColor(status.color) // macOS 13 compatible
            .pillBackground(color: status.color, opacity: 0.18, borderOpacity: 0.0)
    }
}
