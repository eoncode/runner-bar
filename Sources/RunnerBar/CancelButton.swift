import SwiftUI

// MARK: - CancelButton

/// Top-bar cancel button used in JobDetailView and StepLogView.
/// States: idle → loading → done (1.5 s) or failed (1.5 s) → idle.
struct CancelButton: View {
    /// Called on tap. Must invoke completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    /// When true the button is rendered at reduced opacity and cannot be tapped.
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
        Button(action: startCancel) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                Text("Cancel")
                    .font(.caption)
                    .fixedSize()
            }
            .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
            Image(systemName: "xmark.circle")
                .font(.caption)
                .foregroundColor(.red)
            Text("Failed")
                .font(.caption)
                .foregroundColor(.red)
                .fixedSize()
        }
    }

    // MARK: - Actions
    private func startCancel() {
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
