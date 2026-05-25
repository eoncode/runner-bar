// ReRunButton.swift
// RunnerBar
import SwiftUI

// MARK: - ReRunButton
// periphery:ignore
/// Top-bar re-run button.
/// idle (arrow.clockwise + "Re-run") ->
/// loading (spinner + "Running...") ->
/// done (checkmark + "Done", 1.5 s) OR failed (cross + "Failed", 1.5 s) -> idle
struct ReRunButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is completely hidden and takes no layout space.
    var isDisabled: Bool = false

    /// The phase property.
    @State private var phase: Phase = .idle

    // MARK: - Phase
    /// Visual states of the re-run button lifecycle.
    enum Phase {
        /// The `idle` case.
        case idle, loading, done, failed
    }

    // MARK: - Body
    /// The button content, switching between idle, loading, done, and failed states.
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
            Image(systemName: "arrow.clockwise")
                .font(.caption)
            Text("Re-run")
                .font(.caption)
                .fixedSize()
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        if #available(macOS 26, *) {
            Button(action: startRerun) { label }
                .buttonStyle(.plain)
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
        }
    }

    // MARK: - Actions
    /// Transitions the button to `.loading`, invokes `action`, then transitions
    /// to `.done` or `.failed` based on the success flag before resetting to `.idle` after 1.5 s.
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
