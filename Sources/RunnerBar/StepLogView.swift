import AppKit
import SwiftUI

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  StepLogView — LAYOUT + SIZING CONTRACT  ☠️                              ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║  Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).        ║
// ║                                                                              ║
// ║  LAYOUT RULES:                                                               ║
// ║    • Root: .frame(maxWidth:.infinity,                                       ║
// ║                   maxHeight: maxViewHeight,   ← screen-height cap           ║
// ║                   alignment:.top)                                           ║
// ║      maxViewHeight = NSScreen.main.visibleFrame.height - 24                 ║
// ║      The 24 pt offset is the macOS menu-bar height. This ensures the        ║
// ║      popover never overflows the visible screen while still showing as      ║
// ║      much log as possible.                                                  ║
// ║    • Log content MUST be inside the ScrollView.                             ║
// ║    • Header MUST be outside the ScrollView (always visible, not scrolled).  ║
// ║    ❌ NEVER add .idealWidth here                                             ║
// ║    ❌ NEVER add .frame(height:) to the root (clips to fixed size)           ║
// ║    ❌ NEVER add .fixedSize() here                                            ║
// ║    ❌ NEVER change maxHeight to .infinity — fittingSize will return the      ║
// ║       full unbounded log height, making the popover grow off-screen.        ║
// ║                                                                              ║
// ║  onLogLoaded — ☠️ TRAP — READ THIS BEFORE TOUCHING:                         ║
// ║    onLogLoaded fires on the main thread once the async log fetch completes. ║
// ║    AppDelegate wires it to a TWO-HOP async remeasurePopover() call:         ║
// ║                                                                              ║
// ║      onLogLoaded fires (isLoading just flipped false)                       ║
// ║        └─ hop 1: SwiftUI commits isLoading=false, hides spinner             ║
// ║             └─ hop 2: SwiftUI lays out log Text content                     ║
// ║                  └─ remeasurePopover() ← height now reflects log            ║
// ║                                                                              ║
// ║    ONE hop is not enough — fittingSize still reflects the spinner on        ║
// ║    the first run-loop turn after isLoading flips. Two hops are required.    ║
// ║    Width inside remeasurePopover() is ALWAYS AppDelegate.fixedWidth (480).  ║
// ║    NEVER fittingSize.width — that causes the #13 side-jump regression.      ║
// ║                                                                              ║
// ║    ❌ NEVER pass a single-hop or sync resize closure to onLogLoaded         ║
// ║    ❌ NEVER use onLogLoaded to call setFrameSize or contentSize directly     ║
// ║    ❌ NEVER wire onLogLoaded to fittingSize.width                           ║
// ║                                                                              ║
// ║  If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT        ║
// ║  ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment   ║
// ║  is removed is major major major.                                           ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

/// Shows the raw log text for a single `JobStep`.
///
/// Placed by `AppDelegate.navigate()` (rootView swap). Fits the visible screen
/// height; `ScrollView` absorbs overflow so all log lines are reachable.
/// Fetches log on `onAppear` via a background thread.
struct StepLogView: View {
    /// The job that owns this step.
    let job: ActiveJob
    /// The step whose log will be displayed.
    let step: JobStep
    /// Called when the user taps the back button.
    let onBack: () -> Void
    /// Optional callback fired on the main thread once the async log fetch completes.
    ///
    /// AppDelegate wires this to a TWO-HOP async remeasurePopover() so the popover
    /// height updates after the log text is fully laid out by SwiftUI.
    /// See the SIZING CONTRACT comment at the top of this file for full details.
    ///
    /// ❌ NEVER pass a single-hop resize here — fittingSize reflects the spinner
    ///    on the first run-loop turn after isLoading flips false.
    /// ❌ NEVER call setFrameSize / contentSize directly from this closure.
    /// ❌ NEVER pass fittingSize.width into any sizing call — use fixedWidth only.
    /// If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    var onLogLoaded: (() -> Void)? = nil

    /// `nil` = not yet fetched; `""` = fetch returned empty; non-empty = log text.
    @State private var logText: String?
    /// True while the background fetch is in-flight.
    @State private var isLoading = true

    // ⚠️ SIZING CONTRACT — maxViewHeight
    // This is the maximum height this view (and therefore the popover) will grow to.
    // It equals the visible screen height minus the menu-bar (24 pt), so the popover
    // always fits on screen without being clipped by macOS.
    //
    // WHY NOT .infinity:
    //   With maxHeight:.infinity, fittingSize.height returns the full layout height
    //   of the log Text — potentially thousands of points for a long log. AppKit
    //   then sets the popover to that height, which overflows the screen and gets
    //   silently clipped, making the log appear cut off.
    //
    // WHY NOT a fixed constant:
    //   A fixed constant breaks on external monitors or menu-bar-hidden setups.
    //   NSScreen.main.visibleFrame adapts to the actual visible area.
    //
    // ❌ NEVER change maxHeight to .infinity — causes log cut-off via popover overflow.
    // ❌ NEVER replace with a fixed constant — breaks on non-standard screen heights.
    // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    // is major major major.
    private var maxViewHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header — always visible, OUTSIDE ScrollView ──────────────────────
            // ❌ NEVER move this inside the ScrollView — it must stay visible always.
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
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
            // The ScrollView fills the remaining height (bounded by maxViewHeight
            // on the root VStack). For short logs the popover shrinks to fit;
            // for long logs the popover grows to maxViewHeight and the text
            // is scrollable within that space — no content is ever clipped.
            //
            // ❌ NEVER add .frame(height:) here — clips to a fixed size.
            // ❌ NEVER remove the ScrollView — long logs must be scrollable.
            // The popover height is updated via onLogLoaded two-hop remeasure (#21).
            // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
            // ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this
            // comment is removed is major major major.
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
        // ⚠️ maxHeight is LOAD-BEARING — see maxViewHeight comment above.
        // ❌ NEVER change to .infinity — causes log cut-off (popover overflows screen).
        // ❌ NEVER use a fixed constant — adapts to actual visible screen height.
        // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
        .frame(maxWidth: .infinity, maxHeight: maxViewHeight, alignment: .top)
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
                // #21: Fire onLogLoaded so AppDelegate can remeasure the popover
                // height after the log content is fully laid out (two async hops
                // in AppDelegate ensure fittingSize reflects log text, not spinner).
                // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE
                // NOT ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when
                // this comment is removed is major major major.
                onLogLoaded?()
            }
        }
    }
}
