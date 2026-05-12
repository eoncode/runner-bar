import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// ⚠️ POPOVER FRAME REGRESSION GUARD — applies to ALL views in this file
// ════════════════════════════════════════════════════════════════════════
// CancelButton uses .fixedSize() on its text labels — that is SAFE because
// this view is embedded inside an HStack header, never at the root level.
//
// ❌ NEVER wrap CancelButton in a .frame(height:) or .fixedSize() at the
// CALL SITE — that would corrupt the parent view's fittingSize and cause
// the popover to jump sideways when AppDelegate calls navigate().
//
// ✔ The isDisabled=true state returns EmptyView, completely removing the
// button from layout so it occupies zero space in the header HStack.
// The Spacer() before ReRunButton already keeps ReRunButton right-aligned,
// so removing CancelButton from layout has no effect on ReRunButton position.
// ❌ Do NOT revert to opacity(0) — that leaves a blank gap in the header.
// ════════════════════════════════════════════════════════════════════════

/// Top-bar cancel button used in JobDetailView, ActionDetailView, and StepLogView.
///
/// States: idle (xmark.circle + "Cancel") → loading (spinner + "Running…") → done (✓ + "Done", 1.5 s) OR failed (✗ + "Failed", 1.5 s) → idle
///
/// When `isDisabled` is true the button returns **EmptyView** and occupies no space.
/// This is intentional: keeping a zero-opacity placeholder creates a blank gap in the header.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is removed from layout entirely (returns EmptyView).
    /// ⚠️ Do NOT change to .opacity(0.4) or .opacity(0) — see regression guard above.
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
        // ✔ Return EmptyView when disabled — zero layout space, zero hit area.
        // ❌ NEVER use .opacity(0) here — it keeps the space occupied (blank gap).
        if isDisabled { return AnyView(EmptyView()) }
        return AnyView(Group {
            switch phase {
            case .idle:
                Button(action: startCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                        Text("Cancel")
                            .font(.caption)
                            // ✔ .fixedSize() here is SAFE — this is a label inside HStack,
                            // not a root view. It just prevents the text from wrapping.
                            .fixedSize()
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
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
        })
    }

    private func startCancel() {
        guard phase == .idle else { return }
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                phase = success ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    phase = .idle
                }
            }
        }
    }
}
