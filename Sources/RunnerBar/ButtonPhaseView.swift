import SwiftUI

// MARK: - ButtonPhase

/// Phase state used by action buttons (ReRunButton, CancelButton).
enum ButtonPhase {
    case idle
    case loading
    case success
    case failure
}

// MARK: - ButtonPhaseView

/// Shared button renderer used by `ReRunButton` and `CancelButton`.
///
/// Renders one of four states:
/// - `.idle`    → idleIcon + idleLabel (tappable)
/// - `.loading` → spinner + "Running…"
/// - `.success` → green checkmark + "Done"
/// - `.failure` → red cross + "Failed"
struct ButtonPhaseView: View {
    let phase: ButtonPhase
    let idleLabel: String
    let idleIcon: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            if case .idle = phase { action() }
        }) {
            Group {
                switch phase {
                case .idle:
                    HStack(spacing: 4) {
                        Image(systemName: idleIcon).font(.caption)
                        Text(idleLabel).font(.caption).fixedSize()
                    }
                    .foregroundColor(.secondary)
                case .loading:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Running\u{2026}").font(.caption).foregroundColor(.secondary).fixedSize()
                    }
                case .success:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.caption).foregroundColor(.green)
                        Text("Done").font(.caption).foregroundColor(.green).fixedSize()
                    }
                case .failure:
                    HStack(spacing: 4) {
                        Image(systemName: "xmark").font(.caption).foregroundColor(.red)
                        Text("Failed").font(.caption).foregroundColor(.red).fixedSize()
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
