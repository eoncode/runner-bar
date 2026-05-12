import SwiftUI

/// Top-bar re-run button. Mirrors CancelButton phase-machine pattern.
/// idle (arrow.clockwise + "Re-run") → loading (spinner + "Running…") → done (✓ + "Done", 1.5s) OR failed (✗ + "Failed", 1.5s) → idle
struct ReRunButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    /// Visual states of the re-run button lifecycle.
    enum Phase {
        /// Normal tappable state.
        case idle
        /// Spinner shown while the re-run request is in-flight.
        case loading
        /// Green checkmark shown for 1.5 s after success.
        case done
        /// Red cross shown for 1.5 s after failure.
        case failed
    }

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
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Running…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            case .done:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Done")
                        .font(.caption)
                        .foregroundColor(.green)
                        .fixedSize()
                }
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text("Failed")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize()
                }
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
