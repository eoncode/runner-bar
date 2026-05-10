import AppKit
import SwiftUI

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  StepLogView — LAYOUT + SIZING CONTRACT  ☠️                              ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║  Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).        ║
// ║                                                                              ║
// ║  LAYOUT RULES:                                                               ║
// ║    • Root: .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)  ║
// ║    • Log content MUST be inside the ScrollView.                             ║
// ║    • Header MUST be outside the ScrollView (always visible, not scrolled).  ║
// ║    ❌ NEVER add .idealWidth here                                             ║
// ║    ❌ NEVER add .frame(height:) here                                         ║
// ║    ❌ NEVER add .fixedSize() here                                            ║
// ║    ❌ NEVER add .frame(maxHeight:) to the ScrollView                        ║
// ║                                                                              ║
// ║  onLogLoaded — ☠️ TRAP — READ THIS BEFORE TOUCHING:                         ║
// ║    onLogLoaded exists as an optional closure. AppDelegate does NOT pass it.  ║
// ║    In the past someone passed a remeasurePopover() closure here which        ║
// ║    called setFrameSize + contentSize while popover.isShown == true.         ║
// ║    This caused the popover to jump sideways on screen (issue #13).          ║
// ║    AppDelegate intentionally leaves onLogLoaded = nil at both call sites:   ║
// ║      - logView(job:step:)                                                    ║
// ║      - logViewFromAction(job:step:group:)                                    ║
// ║    The ScrollView absorbs log content of any length. No resize is needed.   ║
// ║    ❌ NEVER pass a resize/remeasure closure to onLogLoaded                  ║
// ║    ❌ NEVER use onLogLoaded to call setFrameSize or contentSize              ║
// ║    ❌ NEVER wire onLogLoaded to any AppKit sizing API                        ║
// ║                                                                              ║
// ║  If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT        ║
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
    /// Optional callback fired on the main thread when the async log fetch completes.
    ///
    /// ☠️ AppDelegate does NOT pass this closure. It exists only as an extension
    /// point. If you are tempted to pass a resize/remeasure closure here, read
    /// the SIZING CONTRACT comment at the top of this file first. Passing any
    /// AppKit sizing call here while popover.isShown == true will reintroduce
    /// issue #13 (popover side-jump on log load). Don't do it.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
    var onLogLoaded: (() -> Void)? = nil

    /// `nil` = not yet fetched; `""` = fetch returned empty; non-empty = log text.
    @State private var logText: String?
    /// True while the background fetch is in-flight.
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header — always visible, OUTSIDE ScrollView ──────────────────────
            // ❌ NEVER move this inside the ScrollView — it must stay visible always.
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
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
            // ❌ NEVER add .frame(maxHeight:) to this ScrollView.
            // ❌ NEVER add .frame(height:) to this ScrollView.
            // The popover height is set once in openPopover() via fittingSize.
            // The ScrollView is what absorbs log content of any length safely.
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
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
        }
        // ❌ NEVER change maxHeight to a fixed value — the popover height is
        // driven by fittingSize in openPopover(), not by this frame modifier.
        // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                // ☠️ onLogLoaded is intentionally nil in production.
                // AppDelegate does NOT pass this closure.
                // If you are reading this because you want to add a resize call:
                // STOP. Read the SIZING CONTRACT at the top of this file.
                // Calling any AppKit sizing API here causes issue #13 (side-jump).
                // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed is major major major.
                onLogLoaded?()
            }
        }
    }
}
