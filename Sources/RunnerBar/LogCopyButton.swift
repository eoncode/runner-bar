import AppKit
import SwiftUI

/// Top-bar copy button shared by ActionDetailView, JobDetailView, and StepLogView.
/// States: idle (doc.on.doc + "Copy log") → loading (spinner + "Copying…") → done (✓ + "Done", 1.5s) OR failed (✗ + "Failed", 1.5s) → idle
struct LogCopyButton: View {
    /// Called on tap. Pass nil or empty string on failure — button still resets to idle.
    let fetch: (@escaping (String?) -> Void) -> Void
    /// When true the button is rendered at reduced opacity and cannot be tapped.
    var isDisabled: Bool = false

    @State private var phase: Phase = .idle

    /// Visual states of the copy button lifecycle.
    enum Phase {
        /// Normal tappable state.
        case idle
        /// Spinner shown while fetching log text.
        case loading
        /// Green checkmark shown for 1.5 s after a successful copy.
        case done
        /// Red cross shown for 1.5 s after a failed fetch.
        case failed
    }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button(action: startCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                        Text("Copy log")
                            .font(.caption)
                            .fixedSize()
                    }
                    .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            case .loading:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Copying\u{2026}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            case .done:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("Done")
                        .font(.caption)
                        .foregroundColor(.green)
                        .fixedSize()
                }
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.red)
                    Text("Failed")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize()
                }
            }
        }
    }

    private func startCopy() {
        guard phase == .idle else { return }
        phase = .loading
        fetch { copyText in
            DispatchQueue.main.async {
                if let text = copyText, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    phase = .done
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { phase = .idle }
                } else {
                    phase = .failed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { phase = .idle }
                }
            }
        }
    }
}
