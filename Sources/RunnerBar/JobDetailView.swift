// swiftlint:disable all
// force-v3
import AppKit
import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️ NSPANEL SIZING GUARD — DO NOT REMOVE
// ROOT FRAME RULE: .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
// SCROLLVIEW HEIGHT CAP: .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
// ════════════════════════════════════════════════════════════════════════════════

struct JobDetailView: View {
    let job: ActiveJob
    let tick: Int
    let onBack: () -> Void
    let onSelectStep: (JobStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            infoBar.padding(.horizontal, 12).padding(.bottom, 6)
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    if job.steps.isEmpty {
                        Text("No step data available").font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
                        ForEach(job.steps) { step in
                            Button(action: { onSelectStep(step) }) { stepRow(step) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        .frame(idealWidth: 720, maxWidth: .infinity, alignment: .top)
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) { Image(systemName: "chevron.left").font(.caption); Text("Jobs").font(.caption) }
                    .foregroundColor(.secondary).fixedSize()
            }.buttonStyle(.plain)
            Spacer(minLength: 8)
            actionCluster
            if let urlString = job.htmlUrl, let url = URL(string: urlString) {
                Button(action: { NSWorkspace.shared.open(url) }) {
                    HStack(spacing: 3) { Image(systemName: "safari").font(.caption); Text("GitHub").font(.caption) }
                        .foregroundColor(.secondary).fixedSize()
                }.buttonStyle(.plain).help("Open job on GitHub")
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private var actionCluster: some View {
        HStack(spacing: 4) {
            ReRunButton(action: { completion in
                let jobID = job.id; let slug = self.repoSlug
                DispatchQueue.global(qos: .userInitiated).async {
                    let succeeded = reRunJob(jobID: jobID, repoSlug: slug)
                    DispatchQueue.main.async { completion(succeeded) }
                }
            }, isDisabled: job.status == "in_progress" || job.status == "queued")
            ReRunFailedButton(action: { completion in
                let runID = self.runID; let slug = self.repoSlug
                DispatchQueue.global(qos: .userInitiated).async {
                    let succeeded = reRunFailedJobs(runID: runID, repoSlug: slug)
                    DispatchQueue.main.async { completion(succeeded) }
                }
            }, isDisabled: job.status == "in_progress" || job.status == "queued" || (job.conclusion != "failure" && job.conclusion != "cancelled"))
            CancelButton(action: { completion in
                let runID = self.runID; let slug = self.repoSlug
                DispatchQueue.global(qos: .userInitiated).async {
                    let succeeded = cancelRun(runID: runID, scope: slug)
                    DispatchQueue.main.async { completion(succeeded) }
                }
            }, isDisabled: job.status != "in_progress" && job.status != "queued")
            LogCopyButton(fetch: { completion in
                let jobID = job.id; let slug = self.repoSlug
                DispatchQueue.global(qos: .userInitiated).async { completion(fetchJobLog(jobID: jobID, scope: slug)) }
            }, isDisabled: false)
        }
    }

    private var infoBar: some View {
        let _ = tick
        return HStack(spacing: 6) {
            Text(job.name).font(.system(size: 13, weight: .semibold))
                .foregroundColor(job.isDimmed ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            BranchTagPill(name: repoSlug)
            Spacer()
            if let conclusion = job.conclusion {
                Text(conclusionLabel(conclusion)).font(.caption).foregroundColor(conclusionColor(conclusion))
                    .lineLimit(1).fixedSize()
            } else {
                Text("running").font(.caption).foregroundColor(.rbBlue)
            }
            Text("·").font(.caption).foregroundColor(.secondary)
            Text(job.elapsed).font(.caption.monospacedDigit()).foregroundColor(.secondary).lineLimit(1).fixedSize()
        }
    }

    private var repoSlug: String {
        guard let url = job.htmlUrl else { return "" }
        let parts = url.replacingOccurrences(of: "https://github.com/", with: "").components(separatedBy: "/")
        guard parts.count >= 2 else { return url }
        return parts[0] + "/" + parts[1]
    }

    private var runID: Int {
        guard let url = job.htmlUrl else { return 0 }
        let parts = url.components(separatedBy: "/")
        if let runsIdx = parts.firstIndex(of: "runs"), runsIdx + 1 < parts.count, let id = Int(parts[runsIdx + 1]) { return id }
        return 0
    }

    private func conclusionLabel(_ conclusion: String) -> String {
        switch conclusion {
        case "success": return "✓ SUCCESS"; case "failure": return "✗ FAILED"
        case "cancelled": return "⊘ CANCELLED"; case "skipped": return "⊘ SKIPPED"
        case "action_required": return "! ACTION"; default: return conclusion.uppercased()
        }
    }

    private func conclusionColor(_ conclusion: String) -> Color {
        switch conclusion { case "success": return .rbSuccess; case "failure": return .rbDanger; default: return .secondary }
    }

    @ViewBuilder private func stepRow(_ step: JobStep) -> some View {
        HStack(spacing: 6) {
            Text("#\(String(format: "%02d", step.id))").font(.caption2.monospacedDigit()).foregroundColor(.secondary).frame(width: 28, alignment: .leading)
            Image(systemName: stepIcon(step)).foregroundColor(stepColor(step)).frame(width: 14, alignment: .center)
            Text(step.name ?? "").font(RBFont.mono)
                .foregroundColor(step.status == "queued" ? .secondary : .primary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer()
            if step.startedAt != nil {
                stepTimeRange(step)
                Text(step.elapsed).font(.caption.monospacedDigit()).foregroundColor(.secondary).fixedSize()
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
            .fill(DesignTokens.Colors.rowBackground)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Spacing.cardRadius, style: .continuous)
                .strokeBorder(DesignTokens.Colors.rowBorder, lineWidth: 0.5)))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func stepTimeRange(_ step: JobStep) -> some View {
        HStack(spacing: 3) {
            Text(startLabel(for: step)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Text("→").font(.caption).foregroundColor(.secondary)
            if let endDate = step.completedAt { Text(Self.timeFormatter.string(from: endDate)).font(.caption.monospacedDigit()).foregroundColor(.secondary) }
            else { Text("now").font(.caption).foregroundColor(.rbBlue) }
        }.fixedSize()
    }

    private static let timeFormatter: DateFormatter = { let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"; return fmt }()
    private func startLabel(for step: JobStep) -> String { guard let date = step.startedAt else { return "" }; return Self.timeFormatter.string(from: date) }
    private func stepIcon(_ step: JobStep) -> String {
        switch step.conclusion {
        case "success": return "checkmark.circle.fill"; case "failure": return "xmark.circle.fill"
        case "skipped", "cancelled": return "minus.circle"
        default: return step.status == "in_progress" ? "circle.dotted" : "circle"
        }
    }
    private func stepColor(_ step: JobStep) -> Color {
        switch step.conclusion { case "success": return .rbSuccess; case "failure": return .rbDanger; default: return step.status == "in_progress" ? .rbBlue : .secondary }
    }
}
