import AppKit
import SwiftUI

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  StepLogView — LAYOUT + SIZING CONTRACT  ☠️                              ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║  Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).        ║
// ║                                                                              ║
// ║  LAYOUT RULES:                                                               ║
// ║    • Root: .frame(idealWidth: 480, maxWidth: .infinity, alignment: .top)    ║
// ║    • idealWidth: 480 MUST match AppDelegate.idealWidth (currently 480).     ║
// ║      NSHostingController reads idealWidth as preferredContentSize.width.    ║
// ║      If ANY view in the nav tree omits idealWidth or uses a different       ║
// ║      value, preferredContentSize.width becomes non-deterministic and        ║
// ║      NSPopover re-anchors → side-jump on navigate. (issues #52 #54 #377)   ║
// ║    • Log content MUST be inside the ScrollView.                             ║
// ║    • Header MUST be outside the ScrollView (always visible, not scrolled).  ║
// ║    ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity) — the     ║
// ║       maxHeight: .infinity corrupts fittingSize.width when NSHostingCon-    ║
// ║       troller measures the view unconstrained (AppKit bug, see #375 #376)   ║
// ║    ❌ NEVER omit idealWidth: 480 from the root frame                        ║
// ║    ❌ NEVER add .frame(height:) here                                        ║
// ║    ❌ NEVER add .fixedSize() here                                           ║
// ║    ✅ ScrollView MUST have .frame(maxHeight: visibleFrame * 0.75) cap       ║
// ║       Without it, with sizingOptions=.preferredContentSize, SwiftUI         ║
// ║       reports the full log text height as preferredContentSize.height on    ║
// ║       navigate → NSPopover re-anchors → side-jump. (ref #370)              ║
// ║    ❌ NEVER remove the .frame(maxHeight:) from the ScrollView               ║
// ║                                                                              ║
// ║  If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT     ║
// ║  ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment   ║
// ║  is removed is major major major.                                           ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

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
    var onLogLoaded: (() -> Void)? = nil

    /// `nil` = not yet fetched; `""` = fetch returned empty; non-empty = log text.
    @State private var logText: String?
    /// True while the background fetch is in-flight.
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header — always visible, OUTSIDE ScrollView ──────────────────────
            // ❌ NEVER move this inside the ScrollView — it must stay visible always.
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
                LogCopyButton(
                    fetch: { completion in
                        let text = logText
                        DispatchQueue.global(qos: .userInitiated).async { completion(text) }
                    },
                    isDisabled: logText == nil || logText?.isEmpty == true
                )
                Text(step.elapsed)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)

            Text(step.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Divider()

            // ── Log — INSIDE ScrollView ──────────────────────────────────────────
            // ⚠️ .frame(maxHeight:) cap is REQUIRED on this ScrollView (ref #370).
            // Without it, with sizingOptions=.preferredContentSize, SwiftUI reports
            // the full log text height as preferredContentSize.height on navigate()
            // → NSPopover re-anchors → side-jump.
            // ❌ NEVER remove .frame(maxHeight:) from this ScrollView.
            // ❌ NEVER use a fixed constant — must adapt to screen size.
            ScrollView(.vertical, showsIndicators: true) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small).padding(.vertical, 20)
                        Spacer()
                    }
                } else if let text = logText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    Text("Log not available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            // ⚠️ REQUIRED — caps preferredContentSize.height. Prevents side-jump on navigate.
            // Matches SettingsView and PopoverMainView pattern (issue #370).
            // ❌ NEVER remove this modifier.
            .frame(maxHeight: NSScreen.main.map { $0.visibleFrame.height * 0.75 } ?? 600)
        }
        // ════════════════════════════════════════════════════════════════════════
        // ⚠️ THE ONE FRAME RULE — idealWidth: 480 MUST match AppDelegate.idealWidth.
        // NSHostingController.preferredContentSize.width = idealWidth = 480.
        // Width is constant across all nav states = NSPopover never re-anchors =
        // zero side-jump. Removing idealWidth or using a different value = jump.
        //
        // ❌ NEVER use .frame(maxWidth: .infinity, maxHeight: .infinity)
        //    maxHeight: .infinity corrupts fittingSize.width (AppKit bug #375 #376)
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
        let jobID = job.id
        let stepNum = step.id
        let scope: String = {
            let parts = (job.htmlUrl ?? "").components(separatedBy: "/")
            if parts.count >= 5 {
                let owner = parts[3]
                let repo = parts[4]
                if !owner.isEmpty && !repo.isEmpty { return "\(owner)/\(repo)" }
            }
            return ScopeStore.shared.scopes.first(where: { $0.contains("/") }) ?? ""
        }()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = fetchStepLog(jobID: jobID, stepNumber: stepNum, scope: scope)
            DispatchQueue.main.async {
                logText = text ?? ""
                isLoading = false
                onLogLoaded?()
            }
        }
    }
}
