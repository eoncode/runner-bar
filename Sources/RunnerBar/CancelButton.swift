import SwiftUI

// MARK: - CancelButton

/// Top-bar cancel button for in-progress runs.
struct CancelButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    /// Visual states of the cancel button lifecycle.
    enum Phase { case idle, loading, done, failed }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                if !isDisabled {
                    Button(action: startCancel) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle").font(.caption)
                            Text("Cancel").font(.caption).fixedSize()
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
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
