import AppKit
import SwiftUI

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  ☠️  StepLogView — LAYOUT + SIZING CONTRACT  ☠️                              ║
// ╠══════════════════════════════════════════════════════════════════════════════╣
// ║  Navigation level 3 (PopoverMainView → JobDetailView → StepLogView).        ║
// ║                                                                              ║
// ║  LAYOUT RULES:                                                               ║
// ║    • Root: .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.top)  ║
// ║      ❌ NEVER add a finite maxHeight to the ROOT frame — any finite          ║
// ║         maxHeight on a maxWidth:.infinity root makes fittingSize.width      ║
// ║         non-deterministic, which causes AppKit to recompute the anchor X    ║
// ║         and produce the #13 horizontal side-jump.                           ║
// ║    • Log content MUST be inside the ScrollView.                             ║
// ║    • ScrollView MUST have .frame(maxHeight: maxLogHeight) to bound          ║
// ║         fittingSize.height. Without a cap, fittingSize returns the full     ║
// ║         unbounded log height (1000pt+), the popover overflows the screen,   ║
// ║         and the log appears cut off. The cap is on the ScrollView only —    ║
// ║         NOT the root — so it does not affect fittingSize.width.             ║
// ║    • Header MUST be outside the ScrollView (always visible, not scrolled).  ║
// ║    ❌ NEVER add .idealWidth here                                             ║
// ║    ❌ NEVER add .frame(height:) to the root or ScrollView                   ║
// ║    ❌ NEVER add .fixedSize() here                                            ║
// ║    ❌ NEVER add a finite maxHeight to the ROOT .frame()                      ║
// ║         (causes #13 side-jump via non-deterministic fittingSize.width)      ║
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
/// Placed by `AppDelegate.navigate()` (rootView swap). The ScrollView is capped
/// to the visible screen height so the popover never overflows while all log
/// lines remain reachable by scrolling. Fetches log on `onAppear` via a
/// background thread.
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

    // ⚠️ SIZING CONTRACT — maxLogHeight (applied to ScrollView ONLY, never root)
    //
    // Caps the ScrollView height so fittingSize.height is bounded and the popover
    // never overflows the visible screen area. The header (outside the ScrollView)
    // adds ~60 pt on top, so subtracting 84 pt total gives comfortable clearance.
    //
    // WHY ON ScrollView, NOT THE ROOT:
    //   A finite maxHeight on the ROOT frame (which has maxWidth:.infinity) makes
    //   fittingSize.width non-deterministic — AppKit recomputes the anchor X and
    //   produces the #13 horizontal side-jump. Capping only the ScrollView leaves
    //   the root unconstrained on width, so fittingSize.width stays stable at
    //   AppDelegate.fixedWidth (480) and no side-jump occurs.
    //
    // WHY NOT a fixed constant:
    //   Adapts to external monitors and non-standard screen heights automatically.
    //
    // ❌ NEVER move this cap to the root .frame() — causes #13 side-jump.
    // ❌ NEVER replace with a fixed constant — adapts to actual visible screen height.
    // ❌ NEVER remove entirely — causes popover height explosion with long logs.
    // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    // is major major major.
    private var maxLogHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 84
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
            // maxLogHeight cap is on the ScrollView — NOT the root — so
            // fittingSize.width remains deterministic (no #13 side-jump).
            // For short logs the ScrollView shrinks to content height;
            // for long logs it caps at maxLogHeight and text is scrollable.
            //
            // ❌ NEVER add .frame(height:) here — clips to a fixed size.
            // ❌ NEVER remove .frame(maxHeight:) here — causes height explosion.
            // ❌ NEVER move the cap to the root frame — causes #13 side-jump.
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
            .frame(maxHeight: maxLogHeight)
        }
        // ❌ NEVER add a finite maxHeight to this root frame — causes #13 side-jump
        // via non-deterministic fittingSize.width. The ScrollView cap above handles
        // bounding without affecting the width calculation.
        // If your an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
        // UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
        // is major major major.
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
