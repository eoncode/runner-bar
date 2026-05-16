import SwiftUI

// MARK: - InlineJobRowsView

/// Inline expandable list of job rows shown beneath an in-progress `ActionRowView`.
struct InlineJobRowsView: View {
    /// The parent action group whose jobs are listed.
    let group: ActionGroup
    /// Monotonically incrementing tick used to force elapsed-time re-evaluation.
    let tick: Int
    /// Optional callback fired when the user taps a job row to open the detail view.
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    @State private var cap = 4
    @Environment(\.popoverOpenState) private var popoverOpenState

    private var activeJobs: [ActiveJob] {
        group.jobs.filter { $0.status == "in_progress" || $0.status == "queued" }
    }

    var body: some View {
        ForEach(activeJobs.prefix(cap)) { job in
            if let onSelectJob {
                Button(action: { onSelectJob(job, group) }, label: { jobRow(job) }).buttonStyle(.plain)
            } else {
                jobRow(job)
            }
        }
        if activeJobs.count > cap {
            Button(action: {
                if !popoverOpenState.isOpen { cap += 4 }
            }, label: {
                Text("+ \(activeJobs.count - cap) more jobs\u{2026}")
                    .font(.caption2).foregroundColor(.accentColor)
                    .padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 2)
            })
            .buttonStyle(.plain)
            .disabled(popoverOpenState.isOpen)
        }
    }

    private func jobRow(_ job: ActiveJob) -> some View {
        _ = tick // ⚠️ TICK CONTRACT — DO NOT REMOVE
        return HStack(spacing: 6) {
            Circle()
                .fill(jobDotColor(for: job))
                .frame(width: 5, height: 5)
                .padding(.leading, 12)
            Text(job.name ?? "Job \(job.id)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Text(job.elapsed)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .tokenBlue
        case "queued":      return .tokenOrange
        default:            return .tokenGray
        }
    }
}
