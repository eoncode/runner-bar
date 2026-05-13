import AppKit
import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️⚠️⚠️ NSPANEL SIZING GUARD — READ THIS BEFORE ANY EDIT ⚠️⚠️⚠️
// ════════════════════════════════════════════════════════════════════════════════
//
// ARCHITECTURE: NSPanel (NOT NSPopover). Width is dynamic.
//
// ROOT FRAME RULE:
//   .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
//   • idealWidth: 720 — hints SwiftUI's initial natural width measurement.
//   • NO maxHeight on the root frame.
//
// SCROLLVIEW HEIGHT CAP — REQUIRED:
//   .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
//   ❌ NEVER remove this modifier from the ScrollView.
//   ❌ NEVER use a fixed constant.
//
// ════════════════════════════════════════════════════════════════════════════════
// HISTORY:
//   idealWidth bumped 480 → 560 to accommodate step timing columns.
//   idealWidth bumped 560 → 720 to accommodate action cluster width.
//   Step number badge (#N) added to step rows (step.id is 1-based from GitHub API).
//   Badge width tightened 28 → 18 to reduce left dead space (#spacing-fix).
//   Pressable repo / branch / SHA-origin labels added to header metadata row.
//   Elapsed moved from top action bar to beside start→end timestamps (infoBar only).
//   ReRunFailedButton added after ReRunButton.
//   Step number zero-padded to #01…#99 for equal-width alignment.
//   Header collapsed from 4 rows to 2 rows: title+actions on row 1,
//     timing+metadata chips on row 2 — eliminates empty right-side dead space.
// ════════════════════════════════════════════════════════════════════════════════

// Navigation level 2 (Jobs path): step list for a single `ActiveJob`.
// Drill-down chain: PopoverMainView → JobDetailView → StepLogView.
// swiftlint:disable:next type_body_length
struct JobDetailView: View {
    let job: ActiveJob
    let group: ActionGroup
    let onBack: () -> Void
    let onSelectStep: (JobStep) -> Void

    @State private var tick = 0
    @State private var tickTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Row 1: [‹ Jobs] [title — flex] [Re-run][Re-run failed][Cancel][GitHub][Copy log]
            //
            // ⚠️ Elapsed is in infoBar (row 2) ONLY.
            // ❌ NEVER add elapsed back to this row.
            HStack(spacing: 6) {
                // Back
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Jobs").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)

                // Job title — flex, truncates when the panel is very narrow
                Text(job.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                // ── Action cluster ──────────────────────────────────────────────────────
                ReRunButton(
                    action: { completion in
                        let jobID    = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        if scopeStr.isEmpty {
                            log(
                                "ReRunButton › could not derive scope from htmlUrl: "
                                + "\(String(describing: job.htmlUrl))"
                            )
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let isOk = scopeStr.contains("/")
                                && ghPost("repos/\(scopeStr)/actions/jobs/\(jobID)/rerun")
                            completion(isOk)
                        }
                    },
                    isDisabled: job.status == "in_progress" || job.status == "queued"
                )

                ReRunFailedButton(
                    action: { completion in
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        let runID    = runIDFromHtmlUrl(job.htmlUrl)
                        guard scopeStr.contains("/"), let runID else {
                            log(
                                "ReRunFailedButton › could not derive scope/runID from htmlUrl: "
                                + "\(String(describing: job.htmlUrl))"
                            )
                            completion(false)
                            return
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(
                                ghPost("repos/\(scopeStr)/actions/runs/\(runID)/rerun-failed-jobs")
                            )
                        }
                    },
                    isDisabled: job.status == "in_progress"
                        || job.status == "queued"
                        || (job.conclusion != "failure" && job.conclusion != "cancelled")
                )

                CancelButton(
                    action: { completion in
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        let runID    = runIDFromHtmlUrl(job.htmlUrl)
                        guard scopeStr.contains("/"), let runID else {
                            log(
                                "CancelButton › could not derive scope/runID from htmlUrl: "
                                + "\(String(describing: job.htmlUrl))"
                            )
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
                    Button(
                        action: { NSWorkspace.shared.open(url) },
                        label: {
                            HStack(spacing: 3) {
                                Image(systemName: "safari").font(.caption)
                                Text("GitHub").font(.caption)
                            }
                            .foregroundColor(.secondary)
                            .fixedSize()
                        }
                    )
                    .buttonStyle(.plain)
                    .help("Open job on GitHub")
                }

                LogCopyButton(
                    fetch: { completion in
                        let jobID    = job.id
                        let scopeStr = scopeFromHtmlUrl(job.htmlUrl) ?? ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchJobLog(jobID: jobID, scope: scopeStr))
                        }
                    },
                    isDisabled: false
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 3)

            // ── Row 2: [🕓 start→end · elapsed] [· repo · branch · origin]
            //
            // Elapsed lives here and ONLY here.
            // ❌ NEVER move elapsed back to row 1.
            infoBar
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // ── Steps list ───────────────────────────────────────────────────────────────────────
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
                            Button(
                                action: { onSelectStep(step) },
                                label: { stepRow(step) }
                            )
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
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

    // MARK: - Info bar (row 2)
    /// Single caption-height line combining timing + metadata chips.
    /// Layout: 🕓 start→end · elapsed · [repo] [branch] [origin]
    ///
    /// ❌ NEVER split this back into separate timing and metadata rows.
    /// ❌ NEVER move elapsed out of this view and into row 1.
    @ViewBuilder private var infoBar: some View {
        HStack(spacing: 4) {
            // Timing
            if let start = job.startedAt {
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
                Text("·")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(job.isDimmed ? job.elapsed : elapsedLive(tick: tick))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                // Separator before metadata chips
                Text("·")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 1)
            }
            // Metadata chips — repo, branch, origin
            if let repoURL = URL(string: "https://github.com/\(group.repo)") {
                let repoName = group.repo.components(separatedBy: "/").last ?? group.repo
                metadataChip(icon: "folder", label: repoName, url: repoURL, tooltip: group.repo)
            }
            if let branch = group.headBranch,
               let branchURL = URL(
                    string: "https://github.com/\(group.repo)/tree/"
                        + (branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)
               ) {
                metadataChip(
                    icon: "arrow.triangle.branch",
                    label: branch,
                    url: branchURL,
                    tooltip: "Branch: \(branch)"
                )
            }
            let originURL: URL? = {
                let lbl = group.label
                if lbl.hasPrefix("#"),
                   let num = lbl.dropFirst()
                        .components(separatedBy: CharacterSet.decimalDigits.inverted).first,
                   !num.isEmpty {
                    return URL(string: "https://github.com/\(group.repo)/pull/\(num)")
                } else {
                    return URL(string: "https://github.com/\(group.repo)/commit/\(group.headSha)")
                }
            }()
            if let url = originURL {
                let isPR = group.label.hasPrefix("#")
                metadataChip(
                    icon: isPR ? "arrow.triangle.pull" : "chevron.left.forwardslash.chevron.right",
                    label: group.label,
                    url: url,
                    tooltip: isPR
                        ? "Pull request \(group.label)"
                        : "Commit \(group.headSha.prefix(7))"
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// A small pressable label chip: [icon] [text], opens `url` on click.
    @ViewBuilder private func metadataChip(icon: String, label: String, url: URL, tooltip: String) -> some View {
        Button(
            action: { NSWorkspace.shared.open(url) },
            label: {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                    Text(label)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
                .fixedSize()
            }
        )
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Step row
    /// Single-line step row:
    /// [#01] [icon] [name …truncated] [HH:mm:ss → HH:mm:ss] [elapsed] [›]
    @ViewBuilder private func stepRow(_ step: JobStep) -> some View {
        HStack(spacing: 6) {
            // Step number badge — zero-padded, always 3 chars (#01…#99).
            Text(String(format: "#%02d", step.id))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Text(step.conclusionIcon)
                .font(.system(size: 11))
                .foregroundColor(stepColor(step))
                .frame(width: 14, alignment: .center)
            Text(step.name)
                .font(.system(size: 12))
                .foregroundColor(step.status == "queued" ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
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
                        Text("now")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
                .fixedSize()
            }
            Text(step.elapsed)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .fixedSize()
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
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func wallTime(_ date: Date) -> String {
    _wallTimeFmt.string(from: date)
}
