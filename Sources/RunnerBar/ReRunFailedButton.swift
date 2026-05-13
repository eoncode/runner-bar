import SwiftUI

// MARK: - ReRunFailedButton

/// Top-bar "Re-run failed jobs" button.
/// Mirrors ReRunButton’s phase-machine pattern but calls the
/// GitHub “rerun-failed-jobs” endpoint instead of the full rerun endpoint.
///
/// GitHub API: POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs
///
/// idle (exclamationmark.arrow.clockwise + “Re-run failed”) →
/// loading (spinner + “Running…”) →
/// done (✓ + “Done”, 1.5 s) OR failed (✗ + “Failed”, 1.5 s) → idle
struct ReRunFailedButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    // MARK: - Phase
    enum Phase {
        case idle
        case loading
        case done
        case failed
    }

    // MARK: - Body
    var body: some View {
        Group {
            switch phase {
            case .idle:
                idleView
            case .loading:
                loadingView
            case .done:
                doneView
            case .failed:
                failedView
            }
        }
    }

    // MARK: - Phase Views
    private var idleView: some View {
        Group {
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
        }
    }

    private var loadingView: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text("Running\u{2026}")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()
        }
    }

    private var doneView: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundColor(.green)
            Text("Done")
                .font(.caption)
                .foregroundColor(.green)
                .fixedSize()
        }
    }

    private var failedView: some View {
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
