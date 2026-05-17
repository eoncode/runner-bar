import SwiftUI

// MARK: - StatPill
/// Compact ultraThinMaterial pill showing a label + value (e.g. "CPU 3.2%").
/// Used in PopoverLocalRunnerRow to surface per-runner CPU / MEM metrics.
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
struct BranchTagPill: View {
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

// MARK: - cardRow ViewModifier
/// Applies a card-row background with rounded corners.
/// Used by job/action row items inside list-style ScrollViews.
private struct CardRowModifier: ViewModifier {
    /// Corner radius applied to the background rectangle.
    let cornerRadius: CGFloat

    /// Wraps content in a rounded-rect card background with a subtle stroke.
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.rbSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

/// SwiftUI `View` extensions providing reusable row and badge modifiers.
extension View {
    /// Wraps a row in a card-style rounded rectangle background.
    /// - Parameter cornerRadius: Corner radius — prefer `RBRadius` tokens.
    func cardRow(cornerRadius: CGFloat) -> some View {
        modifier(CardRowModifier(cornerRadius: cornerRadius))
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
