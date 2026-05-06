import AppKit
import SwiftUI

/// Top-bar copy button shared by ActionDetailView, JobDetailView, and StepLogView.
/// States: idle (doc.on.doc) → loading (spinner) → done (green checkmark, 1.5s) → idle
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
    }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button(action: startCopy) {
                    Image(systemName: "doc.on.doc")
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
            }
        }
        .frame(width: 20)
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
                    phase = .idle
                }
            }
        }
    }
}
