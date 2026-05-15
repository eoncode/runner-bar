import SwiftUI

// MARK: - CancelButton

/// Top-bar cancel button used in JobDetailView and StepLogView.
/// States: idle → loading → done (1.5 s) or failed (1.5 s) → idle.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is rendered at reduced opacity and cannot be tapped.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    // MARK: - Phase

    /// Visual states of the cancel button lifecycle.
    enum Phase {
        /// Normal tappable state.
        case idle
        /// Spinner shown while the cancel request is in-flight.
        case loading
        /// Green checkmark shown for 1.5 s after success.
        case done
        /// Red cross shown for 1.5 s after failure.
        case failed
    }

    // MARK: - Body

    var body: some View {
        Group {
            if phase == .idle {
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
            } else {
                ButtonPhaseView(phase: phase)
            }
        }
    }

    // MARK: - Actions

    private func startCancel() {
        guard phase == .idle else { return }
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                self.phase = success ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.phase = .idle
                }
            }
        }
    }
}

// MARK: - ButtonPhaseView

/// Renders the non-idle visual state of a `CancelButton` (loading, done, failed).
struct ButtonPhaseView: View {
    /// The phase to render; `.idle` renders as `EmptyView`.
    let phase: CancelButton.Phase

    /// The button visual for the current phase.
    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .scaleEffect(0.6)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            case .idle:
                EmptyView()
            }
        }
    }
}
