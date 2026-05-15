import AppKit
import SwiftUI

// ╔════════════════════════════════════════════════════════════════════════════╗
// ║ ☹️  StepLogView — LAYOUT + SIZING CONTRACT ☹️                             ║
// ╠════════════════════════════════════════════════════════════════════════════╣
// ║ Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).       ║
// ║                                                                            ║
// ║ LAYOUT RULES:                                                              ║
// ║ • Root: .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)      ║
// ║ • idealWidth: 480 hints SwiftUI's initial natural width measurement.        ║
// ║   NSHostingController reads idealWidth as preferredContentSize.width        ║
// ║   on the first layout pass (NSPanel architecture, not NSPopover).           ║
// ║   The panel then resizes to content-driven width via KVO on                ║
// ║   preferredContentSize (see AppDelegate.sizeObservation).                  ║
// ║ • Log content MUST be inside the ScrollView.                               ║
// ║ • Header MUST be outside the ScrollView (always visible, not scrolled).   ║
// ║ ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity) — the      ║
// ║    maxHeight: .infinity corrupts fittingSize.width when NSHostingCon-     ║
// ║    troller measures the view unconstrained (AppKit bug, see #375 #376)    ║
// ║ ❌ NEVER omit idealWidth: 480 from the root frame                         ║
// ║ ❌ NEVER add .frame(height:) here                                         ║
// ║ ❌ NEVER add .fixedSize() here                                            ║
// ║ ✔  ScrollView MUST have .frame(maxHeight: visibleFrame * 0.75) cap        ║
// ║    Without it, with sizingOptions=.preferredContentSize, SwiftUI           ║
// ║    reports the full log text height as preferredContentSize.height on     ║
// ║    navigate → panel grows off-screen. (ref #370)                          ║
// ║ ❌ NEVER remove the .frame(maxHeight:) from the ScrollView                ║
// ║                                                                            ║
// ║ If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT     ║
// ║ ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment   ║
// ║ is removed is major major major.                                           ║
// ╙────────────────────────────────────────────────────────────────────────────╜

/// Shows the raw log text for a single `JobStep`.
///
/// Placed by `AppDelegate.navigate()` (rootView swap). Fits the fixed popover frame;
/// `ScrollView` absorbs overflow. Fetches log on `onAppear` via a background thread.
struct StepLogView: View {
    /// The job that owns this step.
    let job: ActiveJob
    /// The step whose log will be displayed.
    let step: JobStep
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Optional callback fired on the main thread once the async log fetch completes.
    ///
    /// ❌ NEVER call setFrameSize / contentSize directly from this closure.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var onLogLoaded: (() -> Void)?
    /// `nil` = not yet fetched; `""` = fetch returned empty; non-empty = log text.
    @State private var logText: String?
    /// True while the background fetch is in-flight.
    @State private var isLoading = true

    // MARK: - Formatters (static to avoid re-allocation)
    private static let timeFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateFmt: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.caption)
                        Text("Steps").font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                Spacer()
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
                        let text = logText
                        DispatchQueue.global(qos: .userInitiated).async { completion(text) }
                    },
                    isDisabled: logText == nil || logText?.isEmpty == true
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // ── Step name (large) ─────────────────────────────────────────────
            Text(step.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 5)

            // ── Meta rows ────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "briefcase")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(job.name)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer()
                Text("step #\(step.id)")
                    .font(DesignTokens.Font.monoXSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Layout.badgeRadius)
                            .fill(DesignTokens.Color.pillBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.Layout.badgeRadius)
                                    .strokeBorder(DesignTokens.Color.pillBorder, lineWidth: 0.75)
                            )
                    )
                    .fixedSize()
            }
            .padding(.horizontal, 12).padding(.bottom, 3)

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(repoSlug)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .lineLimit(1).fixedSize()
                Spacer()
                Text("job #\(job.id)")
                    .font(DesignTokens.Font.monoXSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Layout.badgeRadius)
                            .fill(DesignTokens.Color.pillBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.Layout.badgeRadius)
                                    .strokeBorder(DesignTokens.Color.pillBorder, lineWidth: 0.75)
                            )
                    )
                    .fixedSize()
            }
            .padding(.horizontal, 12).padding(.bottom, 3)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(startLabel)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .fixedSize()
                Text("→")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(endLabel)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .fixedSize()
                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(step.elapsed)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .fixedSize()
                Text("·")
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                Text(dateLabel)
                    .font(DesignTokens.Font.monoSmall)
                    .foregroundColor(DesignTokens.Color.labelSecondary)
                    .fixedSize()
                Spacer()
                StatusBadge(label: stepStatusLabel, color: stepStatusColor)
            }
            .padding(.horizontal, 12).padding(.bottom, 6)

            Divider()

            // ── Log — INSIDE ScrollView ───────────────────────────────────────
            // ⚠️ .frame(maxHeight:) cap is REQUIRED on this ScrollView (ref #370).
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(.vertical, 20)
                        Spacer()
                    }
                } else if let text = logText, !text.isEmpty {
                    Text(text)
                        .font(DesignTokens.Font.monoXSmall)
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.18))
                } else {
                    Text("Log not available")
                        .font(DesignTokens.Font.monoSmall)
                        .foregroundColor(DesignTokens.Color.labelSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            // ⚠️ REQUIRED — caps preferredContentSize.height. Prevents panel growing off-screen.
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        // ════════════════════════════════════════════════════════════════════════
        // ⚠️ idealWidth: 480 hints the initial panel width before KVO fires.
        // ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ❌ NEVER omit idealWidth: 480
        // ❌ NEVER add .frame(height:) or .fixedSize() here
        // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
        // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment
        // is removed is major major major.
        // ════════════════════════════════════════════════════════════════════════
        .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)
        .onAppear { loadLog() }
    }

    // MARK: - Log loading
    private func loadLog() {
        isLoading = true
        let jobID   = job.id
        let stepNum = step.id
        let scope: String = {
            let parts = (job.htmlUrl ?? "").components(separatedBy: "/")
            if parts.count >= 5 {
                let owner = parts[3]
                let repo  = parts[4]
                if !owner.isEmpty && !repo.isEmpty { return "\(owner)/\(repo)" }
            }
            return ScopeStore.shared.scopes.first(where: { $0.contains("/") }) ?? ""
        }()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = fetchStepLog(jobID: jobID, stepNumber: stepNum, scope: scope)
            DispatchQueue.main.async {
                logText    = text ?? ""
                isLoading  = false
                onLogLoaded?()
            }
        }
    }
}

// MARK: - Derived helpers
/// Derived helper properties for `StepLogView` (status labels, colors, time formatting).
extension StepLogView {
    /// Repo slug derived from job.htmlUrl, e.g. "owner/repo".
    var repoSlug: String {
        let parts = (job.htmlUrl ?? "").components(separatedBy: "/")
        guard parts.count >= 5 else { return "—" }
        let owner = parts[3]; let repo = parts[4]
        return (owner.isEmpty || repo.isEmpty) ? "—" : "\(owner)/\(repo)"
    }

    /// Step conclusion label (uppercased for StatusBadge), or live/queued status.
    var stepStatusLabel: String {
        switch step.conclusion {
        case "success":   return "SUCCESS"
        case "failure":   return "FAILED"
        case "skipped":   return "SKIPPED"
        case "cancelled": return "CANCELLED"
        default: return step.status == "in_progress" ? "RUNNING" : "QUEUED"
        }
    }

    /// Colour used to render `stepStatusLabel` based on conclusion or live status.
    var stepStatusColor: Color {
        switch step.conclusion {
        case "success":              return DesignTokens.Color.statusGreen
        case "failure":              return DesignTokens.Color.statusRed
        case "skipped", "cancelled": return DesignTokens.Color.labelSecondary
        default: return step.status == "in_progress"
            ? DesignTokens.Color.statusBlue
            : DesignTokens.Color.labelSecondary
        }
    }

    /// Formatted start time, or "—" if unavailable.
    var startLabel: String {
        guard let dateValue = step.startedAt else { return "—" }
        return Self.timeFmt.string(from: dateValue)
    }

    /// Formatted end time, or "—" if unavailable.
    var endLabel: String {
        guard let dateValue = step.completedAt else {
            return step.status == "in_progress" ? "running…" : "—"
        }
        return Self.timeFmt.string(from: dateValue)
    }

    /// Date string (yyyy-MM-dd) for context when the step ran.
    var dateLabel: String {
        guard let dateValue = step.startedAt ?? step.completedAt else { return "—" }
        return Self.dateFmt.string(from: dateValue)
    }
}
