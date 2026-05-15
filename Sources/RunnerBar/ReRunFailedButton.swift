// swiftlint:disable identifier_name missing_docs
import SwiftUI

// MARK: - ReRunFailedButton

/// Button for re-running only failed jobs in a workflow run.
struct ReRunFailedButton: View {
    let action: (@escaping (Bool) -> Void) -> Void
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    enum Phase { case idle, loading, done, failed }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                if !isDisabled {
                    Button(action: startRerun) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.caption)
                            Text("Re-run Failed")
                                .font(.caption)
                                .fixedSize()
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            case .loading:
                ButtonPhaseView(phase: .loading)
            case .done:
                ButtonPhaseView(phase: .done)
            case .failed:
                ButtonPhaseView(phase: .failed)
            }
        }
    }

    private func startRerun() {
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
// swiftlint:enable identifier_name missing_docs
