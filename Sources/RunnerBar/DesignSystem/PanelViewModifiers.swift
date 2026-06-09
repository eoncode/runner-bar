// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ uses `.glassEffect(.regular)` — passive containers must NOT
/// use `.interactive()`. The LiquidGlassReference guide restricts `.interactive()`
/// to tappable controls (buttons, icons) only. Applying it to a passive container
/// activates scaling/shimmer on the entire card surface including non-interactive
/// children, which is semantically wrong and wastes GPU compositing budget.
/// Tappable rows handle interactivity at the contentShape/button level via GlassButton.
/// On older OSes falls back to `.ultraThinMaterial` + a subtle stroke overlay.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT convert `StatPill` to `GlassCard` — it is a capsule-shaped inline
/// pill, not a card container. Use `StatPillBackground` instead.
/// ❌ Do NOT add `.interactive()` back to GlassCard — see #963.
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
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
                )
        } else {
            materialFallback(content: content)
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
/// On macOS 26+ applies `.glassEffect(.regular.interactive())` directly to content.
/// On older OSes passes through unstyled.
///
/// ⚠️ Call sites that group multiple `GlassButton` instances side-by-side MUST wrap
/// them in a shared `GlassEffectContainer` so sibling buttons share a single
/// CABackdropLayer sampling region — enabling morphing and avoiding redundant
/// GPU compositing passes. Do NOT embed a `GlassEffectContainer` inside this modifier.
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
            content
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
        }
    }
}

// MARK: - StatPillBackground
/// Background modifier for `StatPill` and `RunnerMetricsBadge` capsule pills.
///
/// macOS 26+: neutral tint at `Color.primary.opacity(0.12)` bleeds through the
/// glass refractive layer the same way coloured pills do — giving natural vibrancy
/// without a static border. The tint was raised from 0.08 to 0.12 so the glass
/// has enough fill to refract. The manual stroke overlay was removed because it
/// fought the glass layer instead of complementing it (at 0.08 there was nothing
/// for the glass to refract, making the stroke look mundane/flat).
///
/// The call site MUST wrap `RunnerMetricsBadge` in its own `GlassEffectContainer`
/// (separate from the card container) so the pill gets a fresh dedicated
/// CABackdropLayer sampling region — same pattern as `StatusBadge` in `metaTrailing`.
/// Without its own container the pill shares the card backdrop and renders
/// with near-zero contrast.
///
/// macOS < 26: `.ultraThinMaterial` in a `Capsule()` (unchanged).
///
/// ❌ Do NOT re-add the manual stroke — it kills glass vibrancy.
/// ❌ Do NOT lower tint below 0.10 — glass needs fill to refract.
/// ❌ Do NOT share container with runnerCard — give the pill its own.
struct StatPillBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.primary.opacity(0.12), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - StatusBadgeBackground
/// Background modifier for `StatusBadge` capsule badges.
///
/// Matches the `DiskPillBadge` pattern exactly:
/// - colour tint layer: `color.opacity(0.15)` in a `Capsule()`
/// - `.glassEffect(.regular, in: Capsule())` on top
///
/// The call site (ActionRowView.metaTrailing) MUST wrap `statusBadge` in a
/// `GlassEffectContainer` so the glass has a dedicated CABackdropLayer sampling
/// region and refracts correctly instead of washing out.
///
/// macOS < 26: tint fill + stroke border (unchanged).
struct StatusBadgeBackground: ViewModifier {
    let color: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(color.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(color.opacity(0.25), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 0.5))
        }
    }
}

// MARK: - BranchTagPillBackground
/// Background modifier for `BranchTagPill` capsule pills.
/// macOS 26+: accent tint layer + `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: `Capsule().strokeBorder(rbAccent.opacity(0.4), lineWidth: 1)` (unchanged).
struct BranchTagPillBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.rbAccent.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(
                Capsule().strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1)
            )
        }
    }
}

// MARK: - CardRowModifier
/// Surface-fill modifier for card rows in scrollable list content.
///
/// ❌ NEVER apply `.glassEffect` here.
/// Apple HIG: glass effects must not be applied to scrollable list content —
/// they break CABackdropLayer sampling and cause visual artefacts during scroll.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
struct CardRowModifier: ViewModifier {
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(elevated ? Color.rbSurfaceElevated : Color.rbSurface)
        )
    }
}

// MARK: - View extensions
extension View {
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    func glassSection(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassSection(cornerRadius: cornerRadius))
    }

    func glassButton(cornerRadius: CGFloat = RBRadius.small) -> some View {
        modifier(GlassButton(cornerRadius: cornerRadius))
    }

    /// Applies the `StatPillBackground` modifier.
    /// ⚠️ The call site MUST wrap `RunnerMetricsBadge` in its OWN `GlassEffectContainer`
    /// (separate from the card container) on macOS 26+ for correct vibrancy.
    func statPillBackground() -> some View {
        modifier(StatPillBackground())
    }

    func statusBadgeBackground(color: Color) -> some View {
        modifier(StatusBadgeBackground(color: color))
    }

    func branchTagPillBackground() -> some View {
        modifier(BranchTagPillBackground())
    }

    /// ❌ NEVER add `.glassEffect` to this modifier.
    func cardRow(elevated: Bool = false) -> some View {
        modifier(CardRowModifier(elevated: elevated))
    }
}

// MARK: - StatPill
/// Compact pill showing a label + value (e.g. "CPU 3.2%").
/// ❌ Do NOT convert to GlassCard — capsule-shaped pill, not a card container.
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
        .statPillBackground()
    }
}

// MARK: - StatusBadge
/// Capsule badge for action-row trailing area.
/// ⚠️ Must be wrapped in a `GlassEffectContainer` at the call site for correct glass rendering.
struct StatusBadge: View {
    let status: RBStatus
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .statusBadgeBackground(color: status.color)
    }
}

// MARK: - BranchTagPill
/// Inline pill displaying a git branch or tag name.
struct BranchTagPill: View { // periphery:ignore — used dynamically inside ActionRowView.rowContent
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
        .branchTagPillBackground()
    }
}

// MARK: - Previews
#if DEBUG
#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("Glass Card").padding().glassCard()
        Text("Glass Card r=10").padding().glassCard(cornerRadius: 10)
    }
    .padding()
}

#Preview("GlassSection") {
    Text("Section Header").padding().glassSection().padding()
}

#Preview("GlassButton") {
    Button(action: {}) {
        Text("Re-run").font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
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
        Text("Standard row").padding().cardRow()
        Text("Elevated row").padding().cardRow(elevated: true)
    }
    .padding()
}
#endif
