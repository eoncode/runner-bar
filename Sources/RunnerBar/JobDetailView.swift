import AppKit
import SwiftUI
// swiftlint:disable vertical_whitespace_opening_braces

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

/// Navigation level 2 (Jobs path): step list for a single `ActiveJob`.
struct JobDetailView: View {
    /// The job whose steps are displayed.
    let job: ActiveJob
    /// Display tick for live elapsed-time updates.
    let tick: Int
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Called when the user taps a step row.
    let onSelectStep: (JobStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            infoBar
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Divider()
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

    // MARK: - Header bar
    private var headerBar: some View {
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
            actionCluster
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
    }

    // MARK: - Action cluster (extracted to fix function_body_length)
    private var actionCluster: some View {
        HStack(spacing: 4) {
            ReRunButton(
                action: { completion in
                    let jobID = job.id
                    let slug  = self.repoSlug
                    DispatchQueue.global(qos: .userInitiated).async {
                        let succeeded = reRunJob(jobID: jobID, repoSlug: slug)
                        DispatchQueue.main.async { completion(succeeded) }
                    }
                },
                isDisabled: job.status == "in_progress" || job.status == "queued"
            )
            ReRunFailedButton(
                action: { completion in
                    let runID = self.runID
                    let slug  = self.repoSlug
                    DispatchQueue.global(qos: .userInitiated).async {
                        let succeeded = reRunFailedJobs(runID: runID, repoSlug: slug)
                        DispatchQueue.main.async { completion(succeeded) }
                    }
                },
                isDisabled: job.status == "in_progress"
                    || job.status == "queued"
                    || (job.conclusion != "failure" && job.conclusion != "cancelled")
            )
            CancelButton(
                action: { completion in
                    let runID = self.runID
                    let slug  = self.repoSlug
                    DispatchQueue.global(qos: .userInitiated).async {
                        let succeeded = cancelRun(runID: runID, scope: slug)
                        DispatchQueue.main.async { completion(succeeded) }
                    }
                },
                isDisabled: job.status != "in_progress" && job.status != "queued"
            )
            LogCopyButton(
                fetch: { completion in
                    let jobID = job.id
                    let slug  = self.repoSlug
                    DispatchQueue.global(qos: .userInitiated).async {
                        completion(fetchJobLog(jobID: jobID, scope: slug))
                    }
                },
                isDisabled: false
            )
        }
    }

    // MARK: - Info bar
    /// Issue #419 Phase 5: BranchTagPill for repo context; rbBlue for in-progress.
    /// `tick` is read here so SwiftUI re-renders elapsed time on every clock tick.
    private var infoBar: some View {
        let _ = tick
        return HStack(spacing: 6) {
            Text(job.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(job.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            BranchTagPill(name: repoSlug)
            Spacer()
            if let conclusion = job.conclusion {
                Text(conclusionLabel(conclusion))
                    .font(.caption)
                    .foregroundColor(conclusionColor(conclusion))
                    .lineLimit(1).fixedSize()
            } else {
                // Issue #419 Phase 5: use rbBlue for in-progress
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

    // MARK: - Derived helpers

    private var repoSlug: String {
        guard let url = job.htmlUrl else { return "" }
        let parts = url
            .replacingOccurrences(of: "https://github.com/", with: "")
            .components(separatedBy: "/")
        guard parts.count >= 2 else { return url }
        return parts[0] + "/" + parts[1]
    }

    /// Extracts the workflow run ID from the job's HTML URL.
    ///
    /// GitHub job URLs have the form:
    ///   https://github.com/owner/repo/actions/runs/<runID>/job/<jobID>
    /// We need the run ID for re-run-failed and cancel-run API calls.
    /// `ActiveJob` has no `runId` field — the run ID lives in `ActionGroup.runs`,
    /// but `JobDetailView` only receives the job. Parsing the URL is the
    /// lightweight alternative to threading the run ID through the nav stack.
    private var runID: Int {
        guard let url = job.htmlUrl else { return 0 }
        let parts = url.components(separatedBy: "/")
        // URL parts: ["", "", "github.com", owner, repo, "actions", "runs", runID, "job", jobID]
        if let runsIdx = parts.firstIndex(of: "runs"),
           runsIdx + 1 < parts.count,
           let id = Int(parts[runsIdx + 1]) {
            return id
        }
        return 0
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
            // step.id is the GitHub API step number (mapped from JSON "number" field)
            Text("#\(String(format: "%02d", step.id))")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            Image(systemName: stepIcon(step))
                .foregroundColor(stepColor(step))
                .frame(width: 14, alignment: .center)
            Text(step.name)
                .font(RBFont.mono)
                .foregroundColor(step.status == "queued" ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer()
            if step.startedAt != nil {
                stepTimeRange(step)
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

    /// Extracted from stepRow to reduce its body length.
    @ViewBuilder private func stepTimeRange(_ step: JobStep) -> some View {
        HStack(spacing: 3) {
            Text(startLabel(for: step))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Text("→")
                .font(.caption)
                .foregroundColor(.secondary)
            if let endDate = step.completedAt {
                Text(Self.timeFormatter.string(from: endDate))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Text("now")
                    .font(.caption)
                    .foregroundColor(.rbBlue)
            }
        }
        .fixedSize()
    }

    /// Shared static formatter — avoids allocating a new DateFormatter on every row render.
    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    private func startLabel(for step: JobStep) -> String {
        guard let date = step.startedAt else { return "" }
        return Self.timeFormatter.string(from: date)
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
// swiftlint:enable vertical_whitespace_opening_braces
