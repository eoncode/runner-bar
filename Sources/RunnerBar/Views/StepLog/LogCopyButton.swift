// LogCopyButton.swift
// RunnerBar
import AppKit
import SwiftUI

// MARK: - LogCopyButton
/// A toolbar button that copies the full log text to the clipboard.
/// Accepts a `fetch` closure so the caller controls when the copy is resolved
/// (e.g. off the main thread) without coupling the button to a specific data model.
struct LogCopyButton: View {
    /// Closure called when the user taps Copy.
    /// The closure receives a completion that must be called with the optional log text.
    let fetch: (@escaping (String?) -> Void) -> Void
    /// When `true` the button is greyed-out and ignores taps.
    let isDisabled: Bool

    /// Whether the clipboard write has just succeeded (drives the checkmark state).
    @State private var copied = false

    /// The body property.
    var body: some View {
        Button(action: performCopy) {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                Text(copied ? "Copied" : "Copy log")
                    .font(.caption)
            }
            .foregroundColor(isDisabled ? Color.rbTextTertiary : Color.rbTextSecondary)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(isDisabled ? "Log not yet loaded" : "Copy log to clipboard")
    }

    /// Performs the copy: calls `fetch`, writes the result to the pasteboard, and
    /// briefly shows the checkmark state.
    private func performCopy() {
        fetch { text in
            guard let text, !text.isEmpty else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
        }
    }
}
