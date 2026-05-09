import AppKit
import SwiftUI
// swiftlint:disable identifier_name vertical_whitespace_opening_braces superfluous_disable_command

// ═══════════════════════════════════════════════════════════════════════════════
// ⚠️ REGRESSION GUARD — mirrors JobDetailView frame/layout contract
// ═══════════════════════════════════════════════════════════════════════════════
//
// ── LIVE DATA ────────────────────────────────────────────────────────────────────
//   ActionDetailView owns an ActionDetailStore (@StateObject) that polls
//   RunnerStore.shared every 1 s. The group prop from AppDelegate is only the
//   INITIAL snapshot — all live UI reads from liveStore.group instead.
//   ❌ NEVER pass group directly to sub-views — always use liveStore.group.
//
// ── FRAME CONTRACT ───────────────────────────────────────────────────────────────
//   Root uses .frame(maxWidth: .infinity, alignment: .top) — NO maxHeight.
//   Fits to content. ScrollView is capped at maxHeight:360 for overflow.
//   ❌ NEVER add maxHeight:.infinity to root
//   ❌ NEVER add .frame(height:) to root
//
// ── LAYOUT RULES ─────────────────────────────────────────────────────────────────
//   ✔ Header (back button + title + Divider) MUST be OUTSIDE ScrollView
//   ✔ Job list MUST be inside ScrollView
//   ❌ NEVER put header inside ScrollView
//   ❌ NEVER call navigate() directly — use onBack / onSelectJob callbacks
// ═══════════════════════════════════════════════════════════════════════════════

// MARK: - ActionDetailStore

/// Lightweight ObservableObject that keeps ActionDetailView in sync with live
/// RunnerStore data. Polls every 1 s — same cadence as the elapsed tick timer.
///
/// Using a dedicated store (rather than re-using RunnerStoreObservable) avoids
/// cross-talk: ActionDetailView is a pushed detail screen and should not force
/// the entire main view to redraw on every tick.
@MainActor
final class ActionDetailStore: ObservableObject {
    /// The live group, updated every poll tick. Starts as the snapshot passed
    /// from AppDelegate, then replaced with fresh data from RunnerStore.
    @Published private(set) var group: ActionGroup
    private let groupID: String
    private var timer: Timer?

    init(initial group: ActionGroup) {
        self.group = group
        self.groupID = group.id
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Replace with the freshest snapshot from RunnerStore.
                // Falls back to the last known value when the group has left the store
                // (e.g. run was cancelled and purged) so the UI doesn't blank out.
                if let live = RunnerStore.shared.actions.first(where: { $0.id == self.groupID }) {
                    self.group = live
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - ActionDetailView

/// Navigation level 2a (Actions path): shows the flat job list for a commit/PR group.
///
/// Drill-down chain:
///   PopoverMainView (action row tap)
///   → ActionDetailView            ← this view
///   → JobDetailView (step list)   ← existing, unchanged
///   → StepLogView (log)           ← existing, unchanged
struct ActionDetailView: View {
    /// Initial snapshot from AppDelegate. Live data comes from liveStore.group.
    let initialGroup: ActionGroup
    let onBack: () -> Void
    /// Called when user taps a job row. AppDelegate wires this to detailViewFromAction(job:group:).
    let onSelectJob: (ActiveJob) -> Void

    @StateObject private var liveStore: ActionDetailStore

    init(group: ActionGroup, onBack: @escaping () -> Void, onSelectJob: @escaping (ActiveJob) -> Void) {
        self.initialGroup = group
        self.onBack = onBack
        self.onSelectJob = onSelectJob
        _liveStore = StateObject(wrappedValue: ActionDetailStore(initial: group))
    }

    var body: some View {
        let group = liveStore.group
        VStack(alignment: .leading, spacing: 0) {

            // ── Header: OUTSIDE ScrollView — always visible at top
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Actions").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()  // ⚠️ load-bearing — pushes elapsed to right edge
                ReRunButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = runIDs.allSatisfy { runID in
                                ghPost("repos/\(scope)/actions/runs/\(runID)/rerun-failed-jobs")
                            }
                            completion(ok)
                        }
                    },
                    isDisabled: group.groupStatus == .inProgress
                )
                CancelButton(
                    action: { completion in
                        let scope = group.repo
                        let runIDs = group.runs.map { $0.id }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = runIDs.allSatisfy { runID in
                                cancelRun(runID: runID, scope: scope)
                            }
                            completion(ok)
                        }
                    },
                    isDisabled: group.groupStatus != .inProgress
                )
                LogCopyButton(
                    fetch: { completion in
                        let g = group
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchActionLogs(group: g))
                        }
                    },
                    isDisabled: false
                )
                Text(group.elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.label)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let branch = group.headBranch {
                    Text(branch)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(group.jobsDone)/\(group.jobsTotal) jobs concluded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // ── Jobs list: INSIDE ScrollView, capped so view fits to content.
            // maxHeight:360 matches ActionsListView pattern. ScrollView handles overflow.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if group.jobs.isEmpty {
                        Text("No jobs available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(group.jobs) { job in
                            Button(action: { onSelectJob(job) }, label: {
                                HStack(spacing: 8) {
                                    PieProgressView(
                                        progress: job.progressFraction,
                                        color: jobDotColor(for: job),
                                        size: 7
                                    )
                                    Text(job.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(job.isDimmed ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()  // ⚠️ load-bearing
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
            // Cap height so view fits to content for small job counts.
            // ScrollView takes over for large job lists.
            .frame(maxHeight: 360)
            .padding(.bottom, 6)
        }
        // ⚠️ NO maxHeight:.infinity — let VStack size to its content.
        // AppDelegate sizes the popover via fittingSize after navigate().
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { liveStore.start() }
        .onDisappear { liveStore.stop() }
    }

    // MARK: - Job row helpers

    private func jobDotColor(for job: ActiveJob) -> Color {
        switch job.status {
        case "in_progress": return .yellow
        case "queued":      return .blue
        default:
            if job.isDimmed { return .gray }
            return job.conclusion == "success" ? .green : .red
        }
    }

    private func jobStatusLabel(for job: ActiveJob) -> String {
        switch job.status {
        case "in_progress": return "In Progress"
        case "queued":      return "Queued"
        default:            return "Pending"
        }
    }

    private func jobStatusColor(for job: ActiveJob) -> Color {
        job.status == "in_progress" ? .yellow : .secondary
    }

    private func conclusionLabel(_ c: String) -> String {
        switch c {
        case "success":   return "✓ success"
        case "failure":   return "✗ failure"
        case "cancelled": return "⊗ cancelled"
        case "skipped":   return "− skipped"
        default:          return c
        }
    }

    private func conclusionColor(_ c: String) -> Color {
        switch c {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
        }
    }
}
// swiftlint:enable identifier_name vertical_whitespace_opening_braces superfluous_disable_command
