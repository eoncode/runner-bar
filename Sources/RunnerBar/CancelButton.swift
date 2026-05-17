import SwiftUI

// MARK: - CancelButton

/// Top-bar cancel button used in JobDetailView and StepLogView.
/// States: idle → loading → done (1.5 s) or failed (1.5 s) → idle.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is rendered at reduced opacity and cannot be tapped.
    var isDisabled: Bool = false

    @State private var phase: ButtonPhaseView.Phase?

    // MARK: - Body

    /// Renders idle cancel button or delegates to `ButtonPhaseView` for active states.
    var body: some View {
        Group {
            if let phase {
                ButtonPhaseView(phase: phase)
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
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
    }

    // MARK: - Actions

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
