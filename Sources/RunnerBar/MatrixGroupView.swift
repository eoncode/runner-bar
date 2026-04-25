import SwiftUI

// MARK: - Matrix Group View (Phase 3)
// Shows the list of child jobs inside a matrix group.
// Each child job taps into JobStepsView (Phase 1).

struct MatrixGroupView: View {
    let baseName: String
    let jobs: [ActiveJob]
    let scope: String
    let onBack: () -> Void

    @State private var selectedJob: ActiveJob? = nil
    @State private var tick = 0

    var body: some View {
        ZStack {
            // ── Variant list
            if selectedJob == nil {
                variantListView
                    .transition(.move(edge: .leading))
            }

            // ── Job steps drill-down
            if let job = selectedJob {
                JobStepsView(
                    job: job,
                    scope: scope,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.25)) { selectedJob = nil }
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedJob?.id)
    }

    // MARK: - Variant list

    private var variantListView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Text(baseName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(jobs.count) variants")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Variant rows
            ForEach(jobs) { job in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) { selectedJob = job }
                }) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dotColor(for: job))
                            .frame(width: 7, height: 7)

                        Text(job.matrixVariant ?? job.name)
                            .font(.system(size: 12))
                            .foregroundColor(job.isDimmed ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        if job.isDimmed {
                            Text(conclusionLabel(for: job))
                                .font(.caption)
                                .foregroundColor(conclusionColor(for: job))
                                .frame(width: 76, alignment: .trailing)
                        } else {
                            Text(statusLabel(for: job))
                                .font(.caption)
                                .foregroundColor(statusColor(for: job))
                                .frame(width: 76, alignment: .trailing)
                        }

                        Text(liveElapsed(for: job))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(job.isDimmed ? 0.7 : 1.0)
            }
            .padding(.bottom, 6)
        }
        .frame(minWidth: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
    }

    // MARK: - Helpers

    private func liveElapsed(for job: ActiveJob) -> String {
        _ = tick
        return job.elapsed
    }

    private func dotColor(for job: ActiveJob) -> Color {
        if job.isDimmed {
            return job.conclusion == "failure" ? .red : .secondary
        }
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .gray
        default:            return .secondary
        }
    }

    private func statusLabel(for job: ActiveJob) -> String {
        job.status == "in_progress" ? "In Progress" : "Queued"
    }

    private func statusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .yellow : .secondary
    }

    private func conclusionLabel(for job: ActiveJob) -> String {
        switch job.conclusion {
        case "success":   return "✓ success"
        case "failure":   return "✗ failure"
        case "cancelled": return "⊖ cancelled"
        case "skipped":   return "− skipped"
        default:          return job.conclusion ?? "done"
        }
    }

    private func conclusionColor(for job: ActiveJob) -> Color {
        switch job.conclusion {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
        }
    }
}
