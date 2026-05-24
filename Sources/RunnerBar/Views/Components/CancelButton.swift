// CancelButton.swift
// RunnerBar
import RunnerBarCore
import SwiftUI

// MARK: - CancelButton
/// Button that cancels the active workflow run.
/// On macOS 26+ uses Liquid Glass interactive background;
/// on older OSes falls back to the existing bordered button style.
struct CancelButton: View {
    /// The action to invoke when the button is tapped.
    let action: () -> Void
    /// Whether the cancel request is currently in-flight.
    var isLoading: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                Text("Cancel")
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
