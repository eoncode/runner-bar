// ButtonPhaseView.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - ButtonPhaseView
/// Pill badge showing the current phase label for a workflow button.
/// Uses GlassCard for the container surface on all OS versions.
struct ButtonPhaseView: View {
    /// The phase label to display.
    let phase: String

    var body: some View {
        Text(phase)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .glassCard(cornerRadius: 6)
    }
}
