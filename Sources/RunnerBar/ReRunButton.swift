import SwiftUI

// MARK: - ReRunButton

/// Top-bar re-run button.
/// idle (arrow.clockwise + "Re-run") ->
/// loading (spinner + "Running...") ->
/// done (checkmark + "Done", 1.5 s) OR failed (cross + "Failed", 1.5 s) -> idle
struct ReRunButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    // MARK: - Phase

    /// Visual states of the re-run button lifecycle.
    enum Phase {
        /// Normal tappable state — shows arrow.clockwise + "Re-run".
        case idle
        /// In-flight state — shows a spinner + "Running...".
        case loading
        /// Success state — shows a checkmark + "Done" for 1.5 s.
        case done
        /// Failure state — shows a cross + "Failed" for 1.5 s.
        case failed
    }

    // MARK: - Body

    /// The button content, switching between idle, loading, done, and failed states.
    var body: some View {
        Group {
            switch phase {
            case .idle:
                if !isDisabled {
                    Button(action: startRerun) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("Re-run")
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

    // MARK: - Actions

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
