// ReRunFailedButton.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - ReRunFailedButton
/// Button that re-runs only the failed jobs in a workflow.
/// On macOS 26+ uses Liquid Glass interactive background;
/// on older OSes falls back to the existing bordered button style.
struct ReRunFailedButton: View {
    /// The action to invoke when the button is tapped.
    let action: () -> Void
    /// Whether the re-run request is currently in-flight.
    var isLoading: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                Text("Re-run failed")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassCard(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
