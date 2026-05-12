import AppKit
import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️  NSPANEL SIZING GUARD — READ THIS BEFORE ANY EDIT  ⚠️⚠️⚠️
// ════════════════════════════════════════════════════════════════════════════════
//
// ARCHITECTURE: NSPanel (NOT NSPopover). Width is dynamic.
//
// ROOT FRAME RULE:
//   .frame(idealWidth: 560, maxWidth: .infinity, alignment: .top)
//   • idealWidth: 560 — MUST match AppDelegate.initPanelWidth (currently 560).
//   • NO maxHeight on the root frame.
//
// SCROLLVIEW HEIGHT CAP — REQUIRED:
//   .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
//   ❌ NEVER remove this modifier from the ScrollView.
//   ❌ NEVER use a fixed constant.
//
// ════════════════════════════════════════════════════════════════════════════════
// HISTORY:
//   idealWidth bumped 480 → 560 to match AppDelegate.initPanelWidth.
//   Step number badge (#N) added to step rows (step.id is 1-based from GitHub API).
// ════════════════════════════════════════════════════════════════════════════════

/// Navigation level 2 (Jobs path): step list for a single `ActiveJob`.
///
/// Drill-down chain: PopoverMainView → JobDetailView → StepLogView.
struct JobDetailView: View {
    let job: ActiveJob
    let onBack: () -> Void
    let onSelectStep: (JobStep) -> Void

    @State private var tick = 0
    @State private var tickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Jobs").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)

                Spacer()

                ReRunButton(
                    action: { completion in
                        let jobID = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        if scopeStr.isEmpty {
                            log("ReRunButton › could not derive scope from htmlUrl: \(String(describing: job.htmlUrl))")
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let isOk = scopeStr.contains("/")
                                && ghPost("repos/\(scopeStr)/actions/jobs/\(jobID)/rerun")
                            completion(isOk)
                        }
                    },
                    isDisabled: job.status == "in_progress" || job.status == "queued"
                )

                CancelButton(
                    action: { completion in
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        let runID = runIDFromHtmlUrl(job.htmlUrl)
                        guard scopeStr.contains("/"), let runID else {
                            log("CancelButton › could not derive scope/runID from htmlUrl: \(String(describing: job.htmlUrl))")
                            completion(false)
                            return
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(cancelRun(runID: runID, scope: scopeStr))
                        }
                    },
                    isDisabled: job.status != "in_progress" && job.status != "queued"
                )

                if let urlString = job.htmlUrl, let url = URL(string: urlString) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "safari").font(.caption)
                            Text("GitHub").font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("Open job on GitHub")
                }

                LogCopyButton(
                    fetch: { completion in
                        let jobID = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchJobLog(jobID: jobID, scope: scopeStr))
                        }
                    },
                    isDisabled: false
                )

                Text(job.isDimmed ? job.elapsed : elapsedLive(tick: tick))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Job title ───────────────────────────────────────────────────────
            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.bottom, job.startedAt != nil ? 3 : 8)

            // ── Job timing bar ────────────────────────────────────────────────
            if let start = job.startedAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(wallTime(start))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if let end = job.completedAt {
                        Text(wallTime(end))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("running")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            // ── Steps list ───────────────────────────────────────────────────
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if job.steps.isEmpty {
                        Text("No step data available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(job.steps) { step in
                            Button(action: { onSelectStep(step) }, label: {
                                stepRow(step)
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 560, maxWidth: .infinity, alignment: .top)
        .onAppear {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick += 1 }
        }
        .onDisappear {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Step row

    /// Single-line step row:
    /// [#N] [icon] [name …truncated] [HH:mm:ss → HH:mm:ss] [elapsed] [›]
    ///
    /// #N is left-aligned in a fixed 28pt column so all names line up regardless
    /// of whether there are 1-digit or 2-digit step numbers.
    @ViewBuilder
    private func stepRow(_ step: JobStep) -> some View {
        HStack(spacing: 8) {
            // Step number badge — fixed width so names stay aligned
            Text("#\(step.id)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)

            // Conclusion / status icon
            Text(step.conclusionIcon)
                .font(.system(size: 11))
                .foregroundColor(stepColor(step))
                .frame(width: 14, alignment: .center)

            // Step name — flex, truncates last
            Text(step.name)
                .font(.system(size: 12))
                .foregroundColor(step.status == "queued" ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 4)

            // Wall-clock time range
            if let start = step.startedAt {
                HStack(spacing: 3) {
                    Text(wallTime(start))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text("→")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let end = step.completedAt {
                        Text(wallTime(end))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("running")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
                .fixedSize()  // ✔ SAFE: scoped to inner HStack
            }

            // Elapsed
            Text(step.elapsed)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize()  // ✔ SAFE: scoped
                .frame(width: 40, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success": return .green
        case "failure": return .red
        default: return step.status == "in_progress" ? .yellow : .secondary
        }
    }
}

// MARK: - Wallclock formatter

private let _wallTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

private func wallTime(_ date: Date) -> String {
    _wallTimeFmt.string(from: date)
}
