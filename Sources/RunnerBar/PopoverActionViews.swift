import SwiftUI

// MARK: - ActionRowView

/// A single row in the actions list representing one `ActionGroup`.
struct ActionRowView: View {
    let group: ActionGroup
    let tick: Int
    var onSelect: ((ActionGroup) -> Void)?
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { onSelect?(group) }) {
                rowContent
            }
            .buttonStyle(.plain)
        }
    }

    private var rowContent: some View {
        let _ = tick // ⚠️ TICK CONTRACT — DO NOT REMOVE
        return HStack(spacing: 6) {
            statusDonut
            RunnerTypeIcon(isLocal: group.isLocalGroup ?? false)
            Text(group.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(group.title)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            Text(group.elapsed)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var statusDonut: some View {
        ActionStatusDonut(
            conclusion: group.conclusion,
            status: group.groupStatus,
            size: 14
        )
    }
}

// MARK: - RunnerTypeIcon

/// Tiny icon indicating whether a run used a local (self-hosted) or cloud runner.
struct RunnerTypeIcon: View {
    let isLocal: Bool
    var body: some View {
        Image(systemName: isLocal ? "desktopcomputer" : "cloud")
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }
}
