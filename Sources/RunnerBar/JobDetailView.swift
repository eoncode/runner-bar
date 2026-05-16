import SwiftUI

// MARK: - Job Detail View
struct JobDetailView: View {
    let job: ActiveJob
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            jobHeader
            if isExpanded {
                stepsSection
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Header
    private var jobHeader: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(statusLabel)
                        .font(.system(size: 10))
                        .foregroundColor(statusColor)
                    Text("\u{00b7}").font(.caption).foregroundColor(.secondary)
                    if let duration = job.durationString {
                        Text(duration)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            if !job.steps.isEmpty {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !job.steps.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }
        }
    }

    // MARK: - Steps
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 10)
            ForEach(job.steps) { step in
                StepRow(step: step)
            }
        }
    }

    // MARK: - Helpers
    private var statusLabel: String {
        switch job.conclusion ?? job.status {
        case "success": return "\u{2713} SUCCESS"
        case "failure": return "\u{2717} FAILED"
        case "cancelled": return "\u{2298} CANCELLED"
        case "skipped": return "\u{2298} SKIPPED"
        case "in_progress": return "IN PROGRESS"
        default: return (job.conclusion ?? job.status).uppercased()
        }
    }

    private var statusColor: Color {
        switch job.conclusion ?? job.status {
        case "success": return .green
        case "failure": return .red
        case "cancelled", "skipped": return .secondary
        case "in_progress": return .blue
        default: return .secondary
        }
    }

    private var statusIcon: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Step Row
struct StepRow: View {
    let step: JobStep

    var body: some View {
        HStack(spacing: 6) {
            stepIcon
            Text(step.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(stepTextColor)
            Spacer()
            HStack(spacing: 4) {
                if let duration = step.durationString {
                    Text(duration)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text("\u{2192}").font(.caption).foregroundColor(.secondary)
                Text(stepStatusLabel)
                    .font(.system(size: 10))
                    .foregroundColor(stepStatusColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private var stepStatusLabel: String {
        switch step.conclusion ?? step.status {
        case "success": return "\u{2713}"
        case "failure": return "\u{2717}"
        case "skipped": return "\u{2298}"
        case "in_progress": return "..."
        default: return "\u{2298}"
        }
    }

    private var stepStatusColor: Color {
        switch step.conclusion ?? step.status {
        case "success": return .green
        case "failure": return .red
        case "skipped": return .secondary
        case "in_progress": return .blue
        default: return .secondary
        }
    }

    private var stepTextColor: Color {
        switch step.conclusion ?? step.status {
        case "skipped": return .secondary
        case "failure": return .red
        default: return .primary
        }
    }

    private var stepIcon: some View {
        Group {
            switch step.conclusion ?? step.status {
            case "success":
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case "failure":
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            case "skipped":
                Image(systemName: "minus.circle").foregroundColor(.secondary)
            case "in_progress":
                Image(systemName: "circle.dotted").foregroundColor(.blue)
            default:
                Image(systemName: "circle").foregroundColor(.secondary)
            }
        }
        .font(.system(size: 10))
    }
}
