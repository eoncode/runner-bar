// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ uses `.glassEffect(.regular.interactive())`;
/// on older OSes falls back to `.ultraThinMaterial` + a subtle stroke overlay.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT convert `StatPill` to `GlassCard` — it is a capsule-shaped inline
/// pill, not a card container. Use `StatPillBackground` instead.
struct GlassCard: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card`.
    var cornerRadius: CGFloat
    /// Opacity of the fallback stroke border. Defaults to 0.15; use 0.25 for sections.
    var strokeOpacity: Double

    /// Creates a `GlassCard` modifier with custom corner radius and stroke opacity.
    init(cornerRadius: CGFloat = RBRadius.card, strokeOpacity: Double = 0.15) {
        self.cornerRadius = cornerRadius
        self.strokeOpacity = strokeOpacity
    }

    /// Applies the glass card effect to the given content view.
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(
                content.glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            )
        } else {
            AnyView(materialFallback(content: content))
        }
    }

    /// Returns the pre-macOS-26 material + stroke fallback for the given content.
    private func materialFallback(content: Content) -> some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassSection
/// Prominent Liquid Glass modifier for section headers and containers.
/// Delegates to `GlassCard` with stronger stroke opacity (0.25).
struct GlassSection: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card`.
    var cornerRadius: CGFloat

    /// Creates a `GlassSection` modifier with the given corner radius.
    init(cornerRadius: CGFloat = RBRadius.card) {
        self.cornerRadius = cornerRadius
    }

    /// Applies a prominent glass section effect to the given content view.
    func body(content: Content) -> some View {
        content.modifier(GlassCard(cornerRadius: cornerRadius, strokeOpacity: 0.25))
    }
}

// MARK: - GlassButton
/// Liquid Glass interactive button modifier.
/// On macOS 26+ wraps content in a `GlassEffectContainer` with `.regular.interactive()`;
/// on older OSes passes through unstyled.
///
/// ❌ Do NOT call `.glassEffect(.regular.interactive())` directly on buttons.
struct GlassButton: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.small`.
    var cornerRadius: CGFloat

    /// Creates a `GlassButton` modifier with the given corner radius.
    init(cornerRadius: CGFloat = RBRadius.small) {
        self.cornerRadius = cornerRadius
    }

    /// Applies the interactive glass button effect to the given content view.
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(
                GlassEffectContainer {
                    content
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                }
            )
        } else {
            AnyView(content)
        }
    }
}

// MARK: - StatPillBackground
/// Background modifier for `StatPill` capsule pills.
/// macOS 26+: native `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: `.ultraThinMaterial` in a `Capsule()` (unchanged).
///
/// ❌ Do NOT use `GlassCard` for StatPill — it is a capsule-shaped inline pill,
/// not a card container.
struct StatPillBackground: ViewModifier {
    /// Applies a glass capsule background (macOS 26+) or ultra-thin material capsule (pre-26).
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(
                content.glassEffect(.regular, in: Capsule())
            )
        } else {
            AnyView(
                content.background(.ultraThinMaterial, in: Capsule())
            )
        }
    }
}

// MARK: - StatusBadgeBackground
/// Background modifier for `StatusBadge` capsule badges.
/// macOS 26+: colour tint layer + `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: `Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)` (unchanged).
struct StatusBadgeBackground: ViewModifier {
    /// The status color used to tint the badge.
    let color: Color

    /// Applies a tinted glass capsule background (macOS 26+) or stroke capsule border (pre-26).
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(
                content
                    .background(color.opacity(0.15), in: Capsule())
                    .glassEffect(.regular, in: Capsule())
            )
        } else {
            AnyView(
                content.background(
                    Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
                )
            )
        }
    }
}

// MARK: - BranchTagPillBackground
/// Background modifier for `BranchTagPill` capsule pills.
/// macOS 26+: `rbAccent` tint layer + `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: `Capsule().strokeBorder(rbAccent.opacity(0.4), lineWidth: 1)` (unchanged).
struct BranchTagPillBackground: ViewModifier {
    /// Applies an accent-tinted glass capsule background (macOS 26+) or stroke capsule border (pre-26).
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            AnyView(
                content
                    .background(Color.rbAccent.opacity(0.12), in: Capsule())
                    .glassEffect(.regular, in: Capsule())
            )
        } else {
            AnyView(
                content.background(
                    Capsule().strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1)
                )
            )
        }
    }
}

// MARK: - CardRowModifier
/// Surface-fill modifier for card rows in scrollable list content.
/// Fills the row background with `rbSurface` or `rbSurfaceElevated` depending
/// on the `elevated` flag.
///
/// ❌ NEVER apply `.glassEffect` here.
/// Apple HIG: glass effects must not be applied to scrollable list content —
/// they break CABackdropLayer sampling and cause visual artefacts during scroll.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
struct CardRowModifier: ViewModifier {
    /// When `true`, uses `rbSurfaceElevated`; otherwise uses `rbSurface`.
    var elevated: Bool = false

    /// Fills the row background with the appropriate surface color.
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(elevated ? Color.rbSurfaceElevated : Color.rbSurface)
        )
    }
}

// MARK: - View extensions
/// Convenience modifiers for applying glass and surface effects to any `View`.
extension View {
    /// Applies the `GlassCard` modifier (interactive glass on macOS 26+, material fallback pre-26).
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    /// Applies the `GlassSection` modifier (prominent glass for section containers).
    func glassSection(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassSection(cornerRadius: cornerRadius))
    }

    /// Applies the `GlassButton` modifier (interactive glass for tappable buttons).
    func glassButton(cornerRadius: CGFloat = RBRadius.small) -> some View {
        modifier(GlassButton(cornerRadius: cornerRadius))
    }

    /// Applies the `StatPillBackground` modifier (glass capsule on macOS 26+, material pre-26).
    func statPillBackground() -> some View {
        modifier(StatPillBackground())
    }

    /// Applies the `StatusBadgeBackground` modifier (tinted glass capsule on macOS 26+).
    func statusBadgeBackground(color: Color) -> some View {
        modifier(StatusBadgeBackground(color: color))
    }

    /// Applies the `BranchTagPillBackground` modifier (accent-tinted glass capsule on macOS 26+).
    func branchTagPillBackground() -> some View {
        modifier(BranchTagPillBackground())
    }

    /// Applies the `CardRowModifier` surface fill.
    /// - Parameter elevated: Use `rbSurfaceElevated` when `true`, `rbSurface` when `false`.
    ///
    /// ❌ NEVER add `.glassEffect` to this modifier — glass must not be applied to
    /// scrollable list content (Apple HIG).
    func cardRow(elevated: Bool = false) -> some View {
        modifier(CardRowModifier(elevated: elevated))
    }
}

// MARK: - StatPill
/// Compact pill showing a label + value (e.g. “CPU 3.2%”).
/// Used in PanelLocalRunnerRow to surface per-runner CPU / MEM metrics.
/// ❌ Do NOT convert to GlassCard — this is a capsule-shaped inline pill,
/// not a card container. Background is provided by `StatPillBackground`.
struct StatPill: View {
    /// The metric label displayed before the value (e.g. "CPU").
    let label: String
    /// The formatted metric value (e.g. "3.6%").
    let value: String

    /// The pill content: label + value in a glass capsule.
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
        .statPillBackground()
    }
}

// MARK: - StatusBadge
/// Capsule badge for action-row trailing area.
/// Renders a colour-matched background/border and label for a given `RBStatus`.
struct StatusBadge: View {
    /// The workflow status used to determine badge color and appearance.
    let status: RBStatus
    /// The short label text displayed inside the badge.
    let text: String

    /// The badge content: a tinted capsule label matching the status color.
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .statusBadgeBackground(color: status.color)
    }
}

// MARK: - BranchTagPill
/// Inline pill displaying a git branch or tag name.
/// Uses an accent-tinted glass capsule on macOS 26+, stroke capsule pre-26.
struct BranchTagPill: View { // periphery:ignore
    /// The branch or tag name displayed inside the pill.
    let name: String

    /// The pill content: a branch icon + name in an accent-tinted capsule.
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
        .branchTagPillBackground()
    }
}

// MARK: - Previews
#if DEBUG
#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("Glass Card")
            .padding()
            .glassCard()
        Text("Glass Card r=10")
            .padding()
            .glassCard(cornerRadius: 10)
    }
    .padding()
}

#Preview("GlassSection") {
    Text("Section Header")
        .padding()
        .glassSection()
        .padding()
}

#Preview("GlassButton") {
    Button(action: { /* preview stub */ }) {
        Text("Re-run")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .glassButton()
    .padding()
}

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

#Preview("CardRowModifier") {
    VStack(spacing: 8) {
        Text("Standard row")
            .padding()
            .cardRow()
        Text("Elevated row")
            .padding()
            .cardRow(elevated: true)
    }
    .padding()
}
#endif
