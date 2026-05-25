// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - StatPill
/// Compact material pill showing a label + value (e.g. "CPU 3.2%").
/// Uses .glassEffect on macOS 26+, .ultraThinMaterial on macOS < 26.
struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(RBFont.statLabel)
                .foregroundColor(.secondary)
            Text(value)
                .font(RBFont.statValue)
                .foregroundColor(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .modifier(StatPillBackground())
    }
}

private struct StatPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - StatusBadge
/// Capsule badge in action-row trailing area.
/// macOS 26+: glass + status tint. macOS < 26: stroke capsule.
struct StatusBadge: View {
    let status: RBStatus
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .modifier(StatusBadgeBackground(color: status.color))
    }
}

private struct StatusBadgeBackground: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(color.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
        }
    }
}

// MARK: - BranchTagPill
/// Inline pill for a git branch or tag name.
/// macOS 26+: glass + accent tint. macOS < 26: stroke capsule.
struct BranchTagPill: View { // periphery:ignore
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .medium))
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(Color.rbAccent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .modifier(BranchTagPillBackground())
    }
}

private struct BranchTagPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.rbAccent.opacity(0.12), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(Capsule().strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - CardRowModifier
/// Flat semi-transparent card surface for scrollable list rows.
/// ❌ NEVER apply .glassEffect here — Apple HIG prohibits glass on scrollable list content.
/// Tokens are near-zero on macOS 26+ so the glass panel backdrop shows through.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
struct CardRowModifier: ViewModifier {
    var elevated: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                    .fill(elevated ? Color.rbSurfaceElevated : Color.rbSurface)
            )
    }
}

// MARK: - View extensions
extension View {
    /// Flat semi-transparent surface for scrollable rows.
    /// ❌ NEVER use for panel-level containers — use glassCard(cornerRadius:) instead.
    func cardRow(elevated: Bool = false) -> some View {
        modifier(CardRowModifier(elevated: elevated))
    }

    /// Liquid Glass card styling for non-scrollable containers (action rows, runner cards).
    /// macOS 26+: .glassEffect. macOS < 26: rbSurfaceElevated fill + clip.
    /// ❌ NEVER apply inside a ScrollView or List — use cardRow(elevated:) for that.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

private struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.rbSurfaceElevated)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Previews
#if DEBUG
#Preview("StatPill") {
    HStack(spacing: 8) {
        StatPill(label: "CPU", value: "3.6%")
        StatPill(label: "MEM", value: "0.2%")
    }
    .padding()
}

#Preview("StatusBadge") {
    VStack(spacing: 8) {
        StatusBadge(status: .inProgress, text: "IN PROGRESS")
        StatusBadge(status: .success, text: "SUCCESS")
        StatusBadge(status: .failed, text: "FAILED")
        StatusBadge(status: .queued, text: "QUEUED")
    }
    .padding()
}

#Preview("BranchTagPill") {
    VStack(spacing: 8) {
        BranchTagPill(name: "feat/redesign-phases-1-5")
        BranchTagPill(name: "main")
    }
    .padding()
}
#endif
