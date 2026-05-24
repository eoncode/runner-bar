// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - StatPill
/// Compact ultraThinMaterial pill showing a label + value (e.g. "CPU 3.2%").
/// Used in PanelLocalRunnerRow to surface per-runner CPU / MEM metrics.
struct StatPill: View {
    /// The short metric label (e.g. "CPU", "MEM").
    let label: String
    /// The formatted metric value (e.g. "3.6%").
    let value: String

    /// Lays out the label and value side-by-side inside a material capsule.
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
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - StatusBadge
/// Capsule-stroked badge used in action-row trailing area.
/// Renders a colour-matched border + label for a given RBStatus.
struct StatusBadge: View {
    /// The status that drives the badge colour.
    let status: RBStatus
    /// The text displayed inside the badge.
    let text: String

    /// Renders the status text inside a colour-matched capsule stroke.
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .strokeBorder(status.color.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - BranchTagPill
/// Inline pill displaying a git branch or tag name.
/// Uses a blue-tinted stroke capsule consistent with the Phase 5 design language.
struct BranchTagPill: View { // periphery:ignore
    /// The branch or tag name to display.
    let name: String

    /// Renders the branch icon and name inside a tinted capsule stroke.
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
        .background(
            Capsule()
                .strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - CardRowModifier
/// Applies Liquid Glass ultraThinMaterial background + subtle white stroke to a card row.
private struct CardRowModifier: ViewModifier {
    /// Corner radius for the rounded rectangle background.
    var cornerRadius: CGFloat = RBRadius.small
    /// Applies the ultraThinMaterial background and white stroke overlay.
    func body(content: Content) -> some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassPanelModifier
/// Applies Liquid Glass regularMaterial background + subtle white stroke + shadow to a container.
private struct GlassPanelModifier: ViewModifier {
    /// Applies the regularMaterial background, white stroke overlay, and drop shadow.
    func body(content: Content) -> some View {
        content
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
    }
}

// MARK: - GlassCardModifier
/// Applies Liquid Glass ultraThinMaterial card styling with a configurable corner radius.
private struct GlassCardModifier: ViewModifier {
    /// Corner radius for the rounded rectangle background. Defaults to `RBRadius.card`.
    var cornerRadius: CGFloat = RBRadius.card
    /// Applies the ultraThinMaterial background and white stroke overlay.
    func body(content: Content) -> some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassSectionModifier
/// Applies a thinMaterial section header background used inside glass card sheets.
private struct GlassSectionModifier: ViewModifier {
    /// Applies the thinMaterial background and bottom separator stroke.
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial)
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(Color.white.opacity(0.1)),
                alignment: .bottom
            )
    }
}

extension View {
    /// Applies the `.cardRow()` Liquid Glass ultraThinMaterial modifier with configurable corner radius.
    func cardRow(cornerRadius: CGFloat = RBRadius.small) -> some View {
        modifier(CardRowModifier(cornerRadius: cornerRadius))
    }

    /// Applies the `.glassPanel()` Liquid Glass regularMaterial modifier.
    func glassPanel() -> some View {
        modifier(GlassPanelModifier())
    }

    /// Applies the `.glassCard()` Liquid Glass ultraThinMaterial card modifier.
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Applies the `.glassSection()` thinMaterial section header modifier.
    func glassSection() -> some View {
        modifier(GlassSectionModifier())
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
