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
//   ❌ NEVER remove this modifier.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
// ALLOWED UNDER ANY CIRCUMSTANCE.
// ════════════════════════════════════════════════════════════════════════════════
//   Issue #419 Phase 5: stepColor / infoBar "running" label use DesignTokens.
//   Issue #419 Phase 5: step rows wrapped in cardRow-style RoundedRectangle background.
//   Issue #419 Phase 5: BranchTagPill wired into infoBar for repo/branch context.
//   Restored: CancelButton in action cluster (spec: no behaviour changes).
//   Restored: LogCopyButton in action cluster (spec: no behaviour changes).
//   Restored: isDisabled guards on ReRunButton + ReRunFailedButton.
// ════════════════════════════════════════════════════════════════════════════════

// Navigation level 2 (Jobs path): step list for a single `ActiveJob`.
struct JobDetailView: View {
    let job: ActiveJob
    let tick: Int
    let onBack: () -> Void
    let onSelectStep: (JobStep) -> Void

    /// Shared HH:mm:ss formatter — `static let` so it is created once, not per render tick.
    /// ❌ NEVER instantiate DateFormatter inline inside a @ViewBuilder or per-call function.
    private static let stepTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────────────────────────────────────
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

                Spacer(minLength: 8)

                // ── Action cluster ──────────────────────────────────────────────────────────────────
                // Restored isDisabled: buttons must be inactive while job is running/queued.
                ReRunButton(
                    action: { completion in
                        let jobID    = job.id
                        let repoSlug = self.repoSlug
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = GitHub.reRunJob(jobID: jobID, repoSlug: repoSlug)
                            DispatchQueue.main.async { completion(ok) }
                        }
                    },
                    isDisabled: job.status == "in_progress" || job.status == "queued",
                    tooltip: "Re-run this job"
                )
                // Restored isDisabled: only enabled when job has failed or been cancelled.
                ReRunFailedButton(
                    action: { completion in
                        let runID    = job.runId
                        let repoSlug = self.repoSlug
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = GitHub.reRunFailed(runID: runID, repoSlug: repoSlug)
                            DispatchQueue.main.async { completion(ok) }
                        }
                    },
                    isDisabled: job.status == "in_progress"
                        || job.status == "queued"
                        || (job.conclusion != "failure" && job.conclusion != "cancelled"),
                    tooltip: "Re-run failed jobs in this workflow run"
                )
                // Restored: CancelButton — spec mandates no behaviour regression.
                CancelButton(
                    action: { completion in
                        let runID    = job.runId
                        let repoSlug = self.repoSlug
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = GitHub.cancelRun(runID: runID, repoSlug: repoSlug)
                            DispatchQueue.main.async { completion(ok) }
                        }
                    },
                    isDisabled: job.status != "in_progress" && job.status != "queued"
                )
                // Restored: LogCopyButton — spec mandates no behaviour regression.
                LogCopyButton(
                    fetch: { completion in
                        let jobID    = job.id
                        let repoSlug = self.repoSlug
                        DispatchQueue.global(qos: .userInitiated).async {
                            completion(fetchJobLog(jobID: jobID, scope: repoSlug))
                        }
                    },
                    isDisabled: false
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
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Info bar ────────────────────────────────────────────────────────────────────────────────────────────────
            infoBar
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            Divider()

            // ── Steps list ────────────────────────────────────────────────────────────────────────────────────
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    if job.steps.isEmpty {
                        Text("No step data available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
                        ForEach(job.steps) { step in
                            Button(action: { onSelectStep(step) }) {
                                stepRow(step)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Info bar
    @ViewBuilder private var infoBar: some View {
        _ = tick
        HStack(spacing: 6) {
            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(job.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            // Issue #419 Phase 5: BranchTagPill shows repo slug context
            BranchTagPill(name: repoSlug)
            Spacer()
            if let conclusion = job.conclusion {
                Text(conclusionLabel(conclusion))
                    .font(.caption)
                    .foregroundColor(conclusionColor(conclusion))
                    .lineLimit(1).fixedSize()
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                // Issue #419 Phase 5: use rbBlue instead of .yellow for in-progress state
                Text("running")
                    .font(.caption)
                    .foregroundColor(.rbBlue)
            }
            Text("·")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(job.elapsed)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1).fixedSize()
        }
    }

    private var repoSlug: String {
        guard let url = job.htmlUrl else { return "" }
        let parts = url
            .replacingOccurrences(of: "https://github.com/", with: "")
            .components(separatedBy: "/")
        guard parts.count >= 2 else { return url }
        return parts[0] + "/" + parts[1]
    }

    private func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success":           return "✓ SUCCESS"
        case "failure":           return "✗ FAILED"
        case "cancelled":         return "⊘ CANCELLED"
        case "skipped":           return "⊘ SKIPPED"
        case "action_required":   return "! ACTION"
        default:                  return conclusion.uppercased()
        }
    }

    private func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion {
        case "success": return .rbSuccess
        case "failure": return .rbDanger
        default:        return .secondary
        }
    }

    // MARK: - Step row
    @ViewBuilder private func stepRow(_ step: JobStep) -> some View {
        HStack(spacing: 6) {
            Text("#\(String(format: "%02d", step.number))")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            Image(systemName: stepIcon(step))
                .foregroundColor(stepColor(step))
                .frame(width: 14, alignment: .center)
            Text(step.name)
                .font(RBFont.mono)
                .foregroundColor(step.status == "queued" ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer()
            if step.startedAt != nil {
                HStack(spacing: 3) {
                    Text(startLabel(for: step))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                    Text("→")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let end = step.completedAt {
                        Text(Self.stepTimeFmt.string(from: end))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    } else {
                        Text("now")
                            .font(.caption)
                            .foregroundColor(.rbBlue)
                    }
                }
                .fixedSize()
                Text(step.elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                .fill(DesignTokens.Colors.rowBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
    }

    // MARK: - Helpers
    private func elapsedLive(tick _: Int) -> String { job.elapsed }

    private func startLabel(for step: JobStep) -> String {
        guard let d = step.startedAt else { return "" }
        return Self.stepTimeFmt.string(from: d)
    }

    private func stepIcon(_ step: JobStep) -> String {
        switch step.conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure": return "xmark.circle.fill"
        case "skipped", "cancelled": return "minus.circle"
        default: return step.status == "in_progress" ? "circle.dotted" : "circle"
        }
    }

    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion {
        case "success": return .rbSuccess
        case "failure": return .rbDanger
        default: return step.status == "in_progress" ? .rbBlue : .secondary
        }
    }
}
