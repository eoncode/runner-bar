import AppKit
import SwiftUI

// MARK: - LogCopyButton

/// A button that fetches log text asynchronously and copies it to the clipboard.
struct LogCopyButton: View {
    var fetch: (@escaping (String?) -> Void) -> Void
    var isDisabled: Bool = false

    @State private var copied = false

    var body: some View {
        Button(action: doCopy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help("Copy log to clipboard")
    }

    private func doCopy() {
        fetch { text in
            DispatchQueue.main.async {
                if let text {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
        }
    }
}
