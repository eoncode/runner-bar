import SwiftUI

// MARK: - Matrix Group View
// Shows the list of child jobs inside a matrix group.
// Each child job taps into JobStepsView.
//
// ============================================================
// ⚠️  WARNING — POPOVER SIZING CONTRACT — READ BEFORE EDITING
// ============================================================
// This view is a nav state inside PopoverView's root Group.
// PopoverView root Group has .frame(idealWidth: 340).
// NSHostingController with sizingOptions=.preferredContentSize
// reads SwiftUI IDEAL size to set preferredContentSize.
//
// RULE: child nav views must NEVER set .frame(width: N).
//   ✗ .frame(width: 340, height: 480)  ← overrides ideal width => left jump
//   ✓ .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
//     fills width (owned by root idealWidth:340), pins height to 480pt
//
// THINGS THAT WILL CAUSE THE LEFT-JUMP REGRESSION:
//   ✗ Using .frame(width: 340) anywhere in this file
//   ✗ Using ZStack with .transition(.move(edge:))
//     => ZStack collapses to zero width in NSPopover context
//     => move transition animates from far left of screen
//     => USE Group + if/else instead, no transitions
//   ✗ Using .frame(minWidth:) or .fixedSize on the outer container
//
// See GitHub issues #53 and #54 before touching any of this.
// ============================================================

struct MatrixGroupView: View {
    let baseName: String
    let jobs: [ActiveJob]
    let scope: String
    let onBack: () -> Void

    @State private var selectedJob: ActiveJob? = nil
    @State private var tick = 0

    var body: some View {
        // ⚠️ Group + if/else, NOT ZStack + .transition(.move)
        // ZStack with move transitions causes content to animate from far left of screen.
        // Group with plain if/else swaps content in-place with no anchor issues.
        Group {
            if let job = selectedJob {
                JobStepsView(
                    job: job,
                    scope: scope,
                    onBack: { selectedJob = nil }
                )
            } else {
                variantListView
            }
        }
        // ⚠️ maxWidth:.infinity — DO NOT use width:340 here.
        // width:340 overrides the root Group's idealWidth:340 and breaks
        // preferredContentSize.width => left jump. See contract above.
        .frame(maxWidth: .infinity, minHeight: 480, maxHeight: 480)
    }

    // MARK: - Variant list

    private var variantListView: some View {
        // ⚠️ No .fixedSize or .frame(minWidth:) here — the outer frame controls size.
        ScrollView(.vertical, showsIndicators: false) {
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
                    Button(action: { selectedJob = job }) {
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

            } // VStack
        } // ScrollView
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
