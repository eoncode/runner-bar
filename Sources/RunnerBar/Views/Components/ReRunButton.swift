// ReRunButton.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - ReRunButton
/// Button that re-runs the entire workflow.
/// On macOS 26+ uses Liquid Glass interactive background;
/// on older OSes falls back to the existing bordered button style.
struct ReRunButton: View {
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
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                Text("Re-run")
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
