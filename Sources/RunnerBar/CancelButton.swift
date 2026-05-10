import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// ⚠️ POPOVER FRAME REGRESSION GUARD — applies to ALL views in this file
// ════════════════════════════════════════════════════════════════════════
// CancelButton uses .fixedSize() on its text labels — that is SAFE because
// this view is embedded inside an HStack header, never at the root level.
//
// ❌ NEVER wrap CancelButton in a .frame(height:) or .fixedSize() at the
//    CALL SITE — that would corrupt the parent view's fittingSize and cause
//    the popover to jump sideways when AppDelegate calls navigate().
//
// ✔ The isDisabled=true state HIDES the button entirely (opacity 0 +
//   allowsHitTesting false). This keeps the HStack width stable so the
//   Re-run button always stays right-aligned next to the elapsed timer.
//   Do NOT change this back to a faded visible state — it caused perceived
//   misalignment of the Re-run button (reported in issue #294).
// ════════════════════════════════════════════════════════════════════════

/// Top-bar cancel button used in JobDetailView, ActionDetailView, and StepLogView.
///
/// States: idle (xmark.circle + "Cancel") → loading (spinner + "Running…") → done (✓ + "Done", 1.5 s) OR failed (✗ + "Failed", 1.5 s) → idle
///
/// When `isDisabled` is true the button is **invisible** (opacity 0, not hit-testable).
/// This is intentional: a faded-but-present Cancel button creates visual noise and makes
/// the Re-run button look misaligned. Hiding it keeps the header toolbar clean.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is invisible and cannot be tapped.
    /// ⚠️ Do NOT change to .opacity(0.4) visible state — see regression guard above.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    /// Visual states of the cancel button lifecycle.
    enum Phase {
        /// Normal tappable state.
        case idle
        /// Spinner shown while the cancellation request is in-flight.
        case loading
        /// Green checkmark shown for 1.5 s after a successful cancellation.
        case done
        /// Red cross shown for 1.5 s after a failed cancellation attempt.
        case failed
    }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button(action: startCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                        Text("Cancel")
                            .font(.caption)
                            // ✔ .fixedSize() here is SAFE — this is a label inside HStack,
                            //   not a root view. It just prevents the text from wrapping.
                            .fixedSize()
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                // ⚠️ When disabled: HIDE entirely, do not just dim.
                // Rationale: a ghost "Cancel" label shifts the Re-run button left and looks
                // broken. The button re-appears automatically when isDisabled becomes false.
                .opacity(isDisabled ? 0 : 1)
                .allowsHitTesting(!isDisabled)
            case .loading:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Running…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            case .done:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Done")
                        .font(.caption)
                        .foregroundColor(.green)
                        .fixedSize()
                }
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text("Failed")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize()
                }
            }
        }
    }

    private func startCancel() {
        guard phase == .idle else { return }
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                phase = success ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { phase = .idle }
            }
        }
    }
}
