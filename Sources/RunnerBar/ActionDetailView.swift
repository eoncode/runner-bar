import AppKit
import SwiftUI

// MARK: - ActionDetailView

/// Detail view for an `ActionGroup` showing all its jobs and their steps.
struct ActionDetailView: View {
    let group: ActionGroup
    let tick: Int
    var onBack: () -> Void = {}
    var onSelectJob: ((ActiveJob, ActionGroup) -> Void)?

    @State private var expandedJobId: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back")

                VStack(alignment: .leading, spacing: 1) {
                    if let branch = group.headBranch {
                        Text(branch)
                            .font(.system(size: 10)).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                overallStatusBadge
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.jobs) { job in
                        jobSection(job)
                    }
                }
            }
        }
    }

    // MARK: - Overall status badge

    private var overallStatusBadge: some View {
        let (label, color) = statusLabelAndColor(status: group.status, conclusion: group.conclusion)
        return Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    // MARK: - Job section

    private func jobSection(_ job: ActiveJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            jobHeader(job)
            progressBar(job)
            if expandedJobId == job.id {
                stepsSection(job)
            }
        }
    }

    private func jobHeader(_ job: ActiveJob) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedJobId = (expandedJobId == job.id) ? nil : job.id
            }
        }) {
            HStack(spacing: 8) {
                jobStatusIcon(job)
                Text(job.name ?? "Job \(job.id)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Spacer()
                _ = tick
                Text(job.elapsed)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Image(systemName: expandedJobId == job.id ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func progressBar(_ job: ActiveJob) -> some View {
        let fraction: CGFloat = CGFloat(job.progressFraction ?? 0)
        let isActive: Bool = job.status == "in_progress" && fraction > 0
        return Group {
            if isActive {
                JobProgressBarView(progress: fraction)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Steps section

    private func stepsSection(_ job: ActiveJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((job.steps ?? []).enumerated()), id: \.element.id) { idx, step in
                stepRow(step, index: idx, job: job)
            }
        }
        .padding(.bottom, 4)
    }

    private func stepRow(_ step: JobStep, index: Int, job: ActiveJob) -> some View {
        let isSelectable = onSelectJob != nil
        let content = HStack(spacing: 8) {
            stepStatusIcon(step)
            Text(step.name ?? "Step \(index + 1)")
                .font(.system(size: 10))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            if let duration = step.duration {
                Text(formatDuration(duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 3)
        .contentShape(Rectangle())

        return Group {
            if isSelectable {
                Button(action: { onSelectJob?(job, group) }) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    // MARK: - Icons

    private func jobStatusIcon(_ job: ActiveJob) -> some View {
        let (icon, color) = iconAndColor(status: job.status, conclusion: job.conclusion)
        return Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundColor(color)
            .frame(width: 14)
    }

    private func stepStatusIcon(_ step: JobStep) -> some View {
        let (icon, color) = iconAndColor(status: step.status, conclusion: step.conclusion)
        return Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundColor(color)
            .frame(width: 12)
    }

    // MARK: - Helpers

    private func iconAndColor(status: String?, conclusion: String?) -> (String, Color) {
        switch conclusion {
        case "success":   return ("checkmark.circle.fill", .tokenGreen)
        case "failure":   return ("xmark.circle.fill",     .tokenRed)
        case "cancelled": return ("slash.circle.fill",     .tokenGray)
        case "skipped":   return ("arrow.right.circle",    .tokenGray)
        default: break
        }
        switch status {
        case "in_progress": return ("circle.dotted",       .tokenBlue)
        case "queued":      return ("clock",               .tokenOrange)
        default:            return ("circle",              .tokenGray)
        }
    }

    private func statusLabelAndColor(status: String?, conclusion: String?) -> (String, Color) {
        if let c = conclusion {
            switch c {
            case "success":   return ("success",   .tokenGreen)
            case "failure":   return ("failed",    .tokenRed)
            case "cancelled": return ("cancelled", .tokenGray)
            case "skipped":   return ("skipped",   .tokenGray)
            default:          return (c,            .tokenGray)
            }
        }
        return (status ?? "unknown", .tokenBlue)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
