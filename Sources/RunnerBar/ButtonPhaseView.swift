import SwiftUI

// MARK: - ButtonPhaseView

/// Shared loading/done/failed phase indicator used by action buttons.
struct ButtonPhaseView: View {
    /// The visual phase to display.
    enum Phase { case loading, done, failed }
    /// The phase currently being rendered.
    let phase: Phase

    var body: some View {
        HStack(spacing: 4) {
            switch phase {
            case .loading:
                ProgressView().scaleEffect(0.6)
                Text("Running…").font(.caption).foregroundColor(.secondary)
            case .done:
                Image(systemName: "checkmark").font(.caption).foregroundColor(.green)
                Text("Done").font(.caption).foregroundColor(.secondary)
            case .failed:
                Image(systemName: "xmark").font(.caption).foregroundColor(.red)
                Text("Failed").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
