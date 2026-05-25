// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ (Swift 6.2+) uses `.glassEffect(.regular.interactive())`;
/// on older OSes falls back to `.ultraThinMaterial` + a subtle stroke overlay.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT convert `StatPill` to `GlassCard` — it is a capsule-shaped inline
/// pill, not a card container.
struct GlassCard: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card` (8 pt).
    var cornerRadius: CGFloat
    /// Opacity of the fallback stroke border. Defaults to 0.15 (card); use 0.25 for sections.
    var strokeOpacity: Double

    /// Creates a `GlassCard` modifier.
    /// - Parameters:
    ///   - cornerRadius: Corner radius of the glass shape. Defaults to `RBRadius.card`.
    ///   - strokeOpacity: Stroke opacity used in the material fallback. Defaults to `0.15`.
    init(cornerRadius: CGFloat = RBRadius.card, strokeOpacity: Double = 0.15) {
        self.cornerRadius = cornerRadius
        self.strokeOpacity = strokeOpacity
    }

    /// Applies Liquid Glass on macOS 26+ and a material fallback on older OSes.
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

    /// Returns the `.ultraThinMaterial` + stroke fallback view used on macOS < 26.
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
/// Prominent Liquid Glass modifier intended for section headers and containers.
/// Delegates to `GlassCard` with a stronger stroke opacity (0.25) to distinguish
/// section containers from regular cards.
struct GlassSection: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card` (8 pt).
    var cornerRadius: CGFloat

    /// Creates a `GlassSection` modifier.
    /// - Parameter cornerRadius: Corner radius of the glass shape. Defaults to `RBRadius.card`.
    init(cornerRadius: CGFloat = RBRadius.card) {
        self.cornerRadius = cornerRadius
    }

    /// Applies interactive Liquid Glass on macOS 26+ and a material fallback on older OSes.
    func body(content: Content) -> some View {
        content.modifier(GlassCard(cornerRadius: cornerRadius, strokeOpacity: 0.25))
    }
}

// MARK: - GlassButton
/// Liquid Glass interactive button modifier.
/// On macOS 26+ (Swift 6.2+) wraps the content in a `GlassEffectContainer`
/// and applies `.glassEffect(.regular.interactive())`; on older OSes returns
/// the content unstyled (buttons already carry their own `.buttonStyle`).
///
/// Use `.glassButton()` on any tappable button-style view instead of calling
/// `.glassEffect(.regular.interactive())` directly.
struct GlassButton: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to
    /// `RBRadius.small` (4 pt).
    var cornerRadius: CGFloat

    /// Creates a `GlassButton` modifier.
    /// - Parameter cornerRadius: Corner radius of the glass shape. Defaults to `RBRadius.small`.
    init(cornerRadius: CGFloat = RBRadius.small) {
        self.cornerRadius = cornerRadius
    }

    /// Wraps the content in a Liquid Glass interactive container on macOS 26+;
    /// passes through unstyled on older OSes.
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

// MARK: - View extensions
/// Convenience modifiers for applying Liquid Glass effects to any `View`.
extension View {
    /// Applies the `GlassCard` modifier to this view.
    /// - Parameter cornerRadius: Corner radius of the glass shape.
    ///   Defaults to `RBRadius.card` (8 pt).
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    /// Applies the `GlassSection` modifier to this view.
    /// - Parameter cornerRadius: Corner radius of the glass shape.
    ///   Defaults to `RBRadius.card` (8 pt).
    func glassSection(cornerRadius: CGFloat = RBRadius.card) -> some View {
        modifier(GlassSection(cornerRadius: cornerRadius))
    }

    /// Applies the `GlassButton` modifier to this view.
    /// - Parameter cornerRadius: Corner radius of the glass shape.
    ///   Defaults to `RBRadius.small` (4 pt).
    func glassButton(cornerRadius: CGFloat = RBRadius.small) -> some View {
        modifier(GlassButton(cornerRadius: cornerRadius))
    }
}

// MARK: - StatPill
/// Compact ultraThinMaterial pill showing a label + value (e.g. "CPU 3.2%").
/// Used in PanelLocalRunnerRow to surface per-runner CPU / MEM metrics.
/// ❌ Do NOT convert to GlassCard — this is a capsule-shaped inline pill,
/// not a card container.
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
/// Renders a colour-matched border and label for a given `RBStatus`.
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

// MARK: - Previews
#if DEBUG
#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("Glass Card")
            .padding()
            .glassCard()
        Text("Glass Card r=8")
            .padding()
            .glassCard(cornerRadius: 8)
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
    Button(action: { /* preview stub — no action needed */ }) {
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
#endif
