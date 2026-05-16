import AppKit
import SwiftUI

/// Top-bar copy button shared by ActionDetailView, JobDetailView, and StepLogView.
/// States: idle → loading → done (1.5s) OR failed (1.5s) → idle
struct LogCopyButton: View {
    let fetch: (@escaping (String?) -> Void) -> Void
    var isDisabled: Bool = false
    @State private var phase: Phase = .idle

    enum Phase { case idle, loading, done, failed }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Button(action: startCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.caption)
                        Text("Copy log").font(.caption).fixedSize()
                    }
                    .foregroundColor(isDisabled ? .secondary.opacity(0.4) : .secondary)
                }
                .buttonStyle(.plain).disabled(isDisabled)
            case .loading:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Copying…").font(.caption).foregroundColor(.secondary).fixedSize()
                }
            case .done:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.caption).foregroundColor(.green)
                    Text("Done").font(.caption).foregroundColor(.green).fixedSize()
                }
            case .failed:
                HStack(spacing: 4) {
                    Image(systemName: "xmark").font(.caption).foregroundColor(.red)
                    Text("Failed").font(.caption).foregroundColor(.red).fixedSize()
                }
            }
        }
    }

    private func startCopy() {
        guard phase == .idle else { return }
        phase = .loading
        fetch { text in
            DispatchQueue.main.async {
                if let text, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    phase = .done
                } else {
                    phase = .failed
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { phase = .idle }
            }
        }
    }
}
