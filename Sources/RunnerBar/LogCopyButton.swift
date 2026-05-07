import SwiftUI
import AppKit

/// Top-bar copy button shared by ActionDetailView, JobDetailView, and StepLogView.
/// States: idle (doc.on.doc) → loading (spinner) → done (green checkmark, 1.5s) → idle
struct LogCopyButton: View {
    /// Called on tap. Must call completion(text) from any thread.
    /// Pass nil or empty string on failure — button still resets to idle.
    let fetch: (@escaping (String?) -> Void) -> Void
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    enum Phase { case idle, loading, done }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button { startCopy() } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(isDisabled ? .secondary.opacity(0.4): .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            case .loading:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .frame(width: 20)
    }

    private func startCopy() {
        guard phase == .idle else { return }
        phase = .loading
        fetch { text in
            DispatchQueue.main.async {
                if let text = text, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    phase = .done
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        phase = .idle
                    }
                } else {
                    phase = .idle
                }
            }
        }
    }
}
