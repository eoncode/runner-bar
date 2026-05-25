// ReRunFailedButton.swift
// RunnerBar
import SwiftUI

// MARK: - ReRunFailedButton
// periphery:ignore
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

    /// The phase property.
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
    /// Renders idle re-run-failed button or delegates to `ButtonPhaseView` for active states.
    var body: some View {
        Group {
            switch phase {
            case .idle:
                if !isDisabled { idleButton }
            case .loading:
                ButtonPhaseView(phase: .loading)
            case .done:
                ButtonPhaseView(phase: .done)
            case .failed:
                ButtonPhaseView(phase: .failed)
            }
        }
    }

    // MARK: - Idle button
    /// Renders the idle state.
    /// macOS 26+: `.glassEffect(.regular, in: RoundedRectangle)` + `rbBorderSubtle`
    /// strokeBorder overlay — no `GlassEffectContainer` (toolbar buttons are individual).
    /// macOS < 26: plain `.buttonStyle(.plain)` (unchanged).
    @ViewBuilder private var idleButton: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "exclamationmark.arrow.clockwise")
                .font(.caption)
            Text("Re-run failed")
                .font(.caption)
                .fixedSize()
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        if #available(macOS 26, *) {
            Button(action: startRerun) { label }
                .buttonStyle(.plain)
                .help("Re-run only the failed and cancelled jobs in this workflow run")
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.small, style: .continuous)
                        .strokeBorder(Color.rbBorderSubtle, lineWidth: 0.5)
                )
        } else {
            Button(action: startRerun) { label }
                .buttonStyle(.plain)
                .help("Re-run only the failed and cancelled jobs in this workflow run")
        }
    }

    // MARK: - Actions
    /// Transitions the button to `.loading`, invokes `action` (which calls the
    /// "rerun-failed-jobs" endpoint), then transitions to `.done` or `.failed`
    /// based on the success flag before resetting to `.idle` after 1.5 s.
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
