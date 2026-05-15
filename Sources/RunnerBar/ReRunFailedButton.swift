import SwiftUI

// MARK: - ReRunFailedButton

/// Button for re-running only failed jobs in a workflow run.
struct ReRunFailedButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    /// Visual states of the re-run-failed button lifecycle.
    enum Phase { case idle, loading, done, failed }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                if !isDisabled {
                    Button(action: startRerun) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise.circle").font(.caption)
                            Text("Re-run Failed").font(.caption).fixedSize()
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

    private func startRerun() {
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
