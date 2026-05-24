// PanelViewModifiers.swift
// RunnerBar
import SwiftUI

// MARK: - StatPill
/// Compact material pill showing a label + value (e.g. "CPU 3.2%").
/// Uses .glassEffect on macOS 26+, .ultraThinMaterial on macOS < 26.
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
        .modifier(StatPillBackground())
    }
}

/// Applies the correct background material for `StatPill` based on OS version.
/// macOS 26+: `.glassEffect(.regular, in: Capsule())`
/// macOS < 26: `.background(.ultraThinMaterial, in: Capsule())`
private struct StatPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - StatusBadge
/// Capsule badge used in action-row trailing area.
/// On macOS 26+: glass capsule with status-color tint overlay.
/// On macOS < 26: colour-matched stroke capsule (original behaviour).
struct StatusBadge: View {
    /// The status that drives the badge colour.
    let status: RBStatus
    /// The text displayed inside the badge.
    let text: String

    /// Renders the status text inside a status-appropriate capsule.
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .modifier(StatusBadgeBackground(color: status.color))
    }
}

/// Applies the correct background for `StatusBadge` based on OS version.
/// macOS 26+: `.glassEffect` with a tinted color overlay.
/// macOS < 26: `Capsule().strokeBorder(...)` (original behaviour).
private struct StatusBadgeBackground: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(color.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(
                    Capsule()
                        .strokeBorder(color.opacity(0.5), lineWidth: 1)
                )
        }
    }
}

// MARK: - BranchTagPill
/// Inline pill displaying a git branch or tag name.
/// On macOS 26+: glass capsule with accent tint overlay.
/// On macOS < 26: blue-tinted stroke capsule (original behaviour).
struct BranchTagPill: View { // periphery:ignore
    /// The branch or tag name to display.
    let name: String

    /// Renders the branch icon and name inside a tinted capsule.
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

/// Applies the correct background for `BranchTagPill` based on OS version.
/// macOS 26+: `.glassEffect` with accent color tint overlay.
/// macOS < 26: `Capsule().strokeBorder(...)` (original behaviour).
private struct BranchTagPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.rbAccent.opacity(0.12), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(
                    Capsule()
                        .strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1)
                )
        }
    }
}

// MARK: - CardRowModifier
/// Applies flat semi-transparent card styling to scrollable list rows.
/// ❌ NEVER apply .glassEffect here — Apple HIG prohibits glass on scrollable list content.
/// Uses the Phase 2 rbSurface / rbSurfaceElevated tokens, which are near-zero on macOS 26+
/// so the glass panel backdrop shows through correctly.
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

extension View {
    /// Applies `CardRowModifier` to this view.
    func cardRow(elevated: Bool = false) -> some View {
        modifier(CardRowModifier(elevated: elevated))
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
