import SwiftUI

/// Top-bar cancel button used in JobDetailView and StepLogView.
/// States: idle → loading → done (1.5 s) or failed (1.5 s) → idle.
struct CancelButton: View {
    let action: (@escaping (Bool) -> Void) -> Void
    var isDisabled: Bool = false
    @State private var phase: Phase = .idle

    enum Phase {
        case idle
        case loading
        case done
        case failed
    }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button(action: startCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle").font(.caption)
                        Text("Cancel").font(.caption).fixedSize()
                    }
                    .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                }
                .buttonStyle(.plain).disabled(isDisabled)
            case .loading: ButtonPhaseView(phase: .loading)
            case .done:    ButtonPhaseView(phase: .done)
            case .failed:  ButtonPhaseView(phase: .failed)
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
