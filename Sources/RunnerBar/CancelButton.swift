import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️ PANEL FRAME REGRESSION GUARD — applies to ALL views in this file
// ════════════════════════════════════════════════════════════════════════════════
// CancelButton uses .fixedSize() on its text labels — that is SAFE because
// this view is embedded inside an HStack header, never at the root level.
//
// ❌ NEVER wrap CancelButton in a .frame(height:) or .fixedSize() at the
// CALL SITE — that would corrupt the parent view's preferredContentSize and cause
// the panel to jump sideways when AppDelegate calls navigate().
//
// ✔ The isDisabled=true state returns EmptyView, completely removing the
// button from layout so it occupies zero space in the header HStack.
// The Spacer() before ReRunButton already keeps ReRunButton right-aligned,
// so removing CancelButton from layout has no effect on ReRunButton position.
// ❌ Do NOT revert to opacity(0) — that leaves a blank gap in the header.
// ════════════════════════════════════════════════════════════════════════════════

/// Top-bar cancel button used in JobDetailView, ActionDetailView, and StepLogView.
///
/// States: idle (xmark.circle + "Cancel") → loading (spinner + "Running…") →
/// done(true) (✓ + "Done", 1.5 s) OR done(false) (✗ + "Failed", 1.5 s) → idle
///
/// When `isDisabled` is true the button returns **EmptyView** and occupies no space.
/// This is intentional: keeping a zero-opacity placeholder creates a blank gap.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is removed from layout entirely (returns EmptyView).
    /// ⚠️ Do NOT change to .opacity(0.4) or .opacity(0) — see regression guard above.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    private enum Phase {
        case idle, loading, done(Bool)
    }

    // ✔ @ViewBuilder lets each branch return its own concrete type — no AnyView erasure.
    // ❌ NEVER revert to `AnyView(Group { switch ... })` — see regression guard above.
    @ViewBuilder
    var body: some View {
        // ✔ Return EmptyView when disabled — zero layout space, zero hit area.
        // ❌ NEVER use .opacity(0) here — it keeps the space occupied (blank gap).
        if isDisabled {
            EmptyView()
        } else {
            switch phase {
            case .idle:
                Button(action: startCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle").font(.caption)
                        Text("Cancel")
                            .font(.caption)
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
            case .done(let success):
                HStack(spacing: 4) {
                    Image(systemName: success ? "checkmark.circle" : "xmark.circle")
                        .font(.caption)
                        .foregroundColor(success ? .green : .red)
                    Text(success ? "Done" : "Failed")
                        .font(.caption)
                        .foregroundColor(success ? .green : .red)
                        .fixedSize()
                }
            }
        }
    }

    private func startCancel() {
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                self.phase = .done(success)
                let delay = DispatchTime.now() + 1.5
                DispatchQueue.main.asyncAfter(deadline: delay) {
                    self.phase = .idle
                }
            }
        }
    }
}
