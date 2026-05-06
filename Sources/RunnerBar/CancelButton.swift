import SwiftUI

/// Top-bar cancel button used in JobDetailView and StepLogView.
/// States: idle (xmark.circle) → loading (spinner) → done (green ✓, 1.5 s) OR failed (red ✗, 1.5 s) → idle
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is rendered at reduced opacity and cannot be tapped.
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
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            case .loading:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .frame(width: 20)
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
