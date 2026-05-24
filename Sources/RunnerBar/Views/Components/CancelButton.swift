// CancelButton.swift
// RunnerBar
import SwiftUI

// MARK: - CancelButton
// periphery:ignore
/// Top-bar cancel button used in JobDetailView and StepLogView.
/// States: idle → loading → done (1.5 s) or failed (1.5 s) → idle.
/// On macOS 26+ the idle button uses .glassEffect; on macOS < 26 it is plain.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is rendered at reduced opacity and cannot be tapped.
    var isDisabled: Bool = false

    /// Current phase of the button lifecycle; `nil` means idle.
    @State private var phase: ButtonPhaseView.Phase?

    // MARK: - Body
    /// Renders the idle cancel button or delegates to `ButtonPhaseView` for active states.
    var body: some View {
        Group {
            if let phase {
                ButtonPhaseView(phase: phase)
            } else {
                idleButton
            }
        }
    }

    // MARK: - Idle button
    /// The idle-state button, styled with glass on macOS 26+ or plain on earlier OS.
    @ViewBuilder
    private var idleButton: some View {
        if #available(macOS 26, *) {
            Button(action: startCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                    Text("Cancel")
                        .font(.caption)
                        .fixedSize()
                }
                .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
            )
            .disabled(isDisabled)
        } else {
            Button(action: startCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                    Text("Cancel")
                        .font(.caption)
                        .fixedSize()
                }
                .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
    }

    // MARK: - Actions
    /// Transitions the button to `.loading`, invokes `action`, then transitions
    /// to `.done` or `.failed` before resetting to `nil` (idle) after 1.5 s.
    private func startCancel() {
        guard phase == nil else { return }
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                self.phase = success ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.phase = nil
                }
            }
        }
    }
}
