import SwiftUI

// ⚠️ REGRESSION GUARD — same frame rules as PopoverMainView (ref #52 #54 #57)
// navigate() = rootView swap ONLY inside the fixed popover frame.
// ❌ NEVER put header inside ScrollView
// ❌ NEVER add .frame(height:) or .fixedSize() to root

/// Navigation level 2 (Actions path): job list for a single `ActionGroup`.
///
/// Drill-down chain: PopoverMainView → ActionDetailView → JobDetailView → StepLogView.
struct ActionDetailView: View {
    /// The action group whose jobs are displayed.
    let group: ActionGroup
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Called when the user taps a job row.
    let onSelectJob: (ActiveJob) -> Void

    /// Drives the live elapsed timer in the header.
    @State private var tick = 0
    /// Retained so it can be invalidated on disappear to prevent a timer leak.
    @State private var tickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header: OUTSIDE ScrollView
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Actions").font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                ReRunButton(
                    action: { completion in
                        let scopeStr = group.repo
                        let runIDs = group.runs.map { $0.id }
                        guard !runIDs.isEmpty else { completion(false); return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let results = runIDs.map {
                                ghPost("repos/\(scopeStr)/actions/runs/\($0)/rerun")
                            }
                            completion(results.contains(true))
                        }
                    },
                    isDisabled: group.groupStatus == .inProgress || group.groupStatus == .queued
                )
                CancelButton(
                    action: { completion in
                        let scopeStr = group.repo
                        let runIDs = group.runs.map { $0.id }
                        guard !runIDs.isEmpty else { completion(false); return }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let results = runIDs.map { cancelRun(runID: $0, scope: scopeStr) }
                            completion(results.contains(true))
                        }
                    },
                    isDisabled: group.groupStatus != .inProgress && group.groupStatus != .queued
                )
                LogCopyButton(
                    fetch: { completion in
                        let grp = group
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchActionLogs(group: grp))
                        }
                    },
                    isDisabled: false
                )
                Text(elapsedLive(tick: tick))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Text(group.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            HStack(spacing: 4) {
                Text(group.headBranch)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("·").font(.caption).foregroundColor(.secondary)
                Text(group.headSha.prefix(7))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()

            // ── Jobs list: INSIDE ScrollView
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if group.jobs.isEmpty {
                        Text("No job data available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(group.jobs) { job in
                            Button(action: { onSelectJob(job) }, label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(jobDotColor(for: job))
                                        .frame(width: 7, height: 7)
                                    Text(job.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(job.isDimmed ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if let conclusion = job.conclusion {
                                        Text(conclusionLabel(conclusion))
                                            .font(.caption)
                                            .foregroundColor(conclusionColor(conclusion))
                                            .frame(width: 76, alignment: .trailing)
                                    } else {
                                        Text(jobStatusLabel(for: job))
                                            .font(.caption)
                                            .foregroundColor(jobStatusColor(for: job))
                                            .frame(width: 76, alignment: .trailing)
                                    }
                                    Text(job.elapsed)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .frame(width: 40, alignment: .trailing)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            tickTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true,
                block: { _ in tick += 1 }
            )
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    /// Returns the group's elapsed time, re-evaluated every tick for live updates.
    private func elapsedLive(tick _: Int) -> String { group.elapsed }

    /// Dot color for a job in the action detail list.
    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued": return .blue
        default: return job.conclusion == "success" ? .green : (job.isDimmed ? .gray : .red)
        }
    }

    /// Status label for a live job.
    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "Running"
        case "queued":      return "Queued"
        default:            return job.status.capitalized
        }
    }

    /// Foreground color for a live job's status label.
    private func jobStatusColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .blue
        default:            return .secondary
        }
    }

    /// Human-readable conclusion label.
    private func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success":   return "Success"
        case "failure":   return "Failed"
        case "cancelled": return "Cancelled"
        case "skipped":   return "Skipped"
        default:          return conclusion.capitalized
        }
    }

    /// Foreground color for a conclusion label.
    private func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success":   return .green
        case "failure":   return .red
        case "cancelled": return .orange
        default:          return .secondary
        }
    }
}
