import SwiftUI

// MARK: - ReRunFailedButton

/// Top-bar "Re-run failed jobs" button.
/// Mirrors ReRunButton's phase-machine pattern but calls the
/// GitHub "rerun-failed-jobs" endpoint instead of the full rerun endpoint.
///
/// GitHub API: POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs
///
/// idle (exclamationmark.arrow.clockwise + "Re-run failed") →
/// loading (spinner + "Running…") →
/// done (✓ + "Done", 1.5 s) OR failed (✗ + "Failed", 1.5 s) → idle
struct ReRunFailedButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    // MARK: - Phase

    /// Visual states of the re-run-failed button lifecycle.
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

    // MARK: - Body

    /// Renders the button in its current phase.
    var body: some View {
        Group {
            switch phase {
            case .idle:
                if !isDisabled {
                    Button(action: startRerun) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.arrow.clockwise")
                                .font(.caption)
                            Text("Re-run failed")
                                .font(.caption)
                                .fixedSize()
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Re-run only the failed and cancelled jobs in this workflow run")
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
