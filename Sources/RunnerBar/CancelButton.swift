import SwiftUI

/// Top-bar cancel button shared by ActionDetailView and JobDetailView.
/// idle (xmark.circle) → loading (spinner) → done (green ✓, 1.5s) OR failed (red ✗, 1.5s) → idle
struct CancelButton: View {
    /// Called on tap. Must call completion(success: Bool) from any thread.
    let action: (@escaping (Bool) -> Void) -> Void
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    enum Phase { case idle, loading, done, failed }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button { startCancel() } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            case .loading:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .frame(width: 20)
    }

    private func startCancel() {
        guard phase == .idle else { return }
        phase = .loading
        action { success in
            DispatchQueue.main.async {
                phase = success ? .done : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { phase = .idle }
            }
        }
    }
}
