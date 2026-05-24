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

    /// Tracks the outcome of the last copy attempt.
    private enum CopyState { case idle, copied, failed }
    /// Current copy-state; drives label and colour.
    @State private var copyState: CopyState = .idle

    /// The body property.
    var body: some View {
        Button(action: performCopy) {
            HStack(spacing: 3) {
                Image(systemName: iconName)
                    .font(.caption)
                Text(label)
                    .font(.caption)
            }
            .foregroundColor(foregroundColor)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
    }

    // MARK: - Derived helpers

    private var iconName: String {
        switch copyState {
        case .idle:   return "doc.on.doc"
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var label: String {
        switch copyState {
        case .idle:   return "Copy log"
        case .copied: return "Copied"
        case .failed: return "Failed"
        }
    }

    private var foregroundColor: Color {
        switch copyState {
        case .idle:   return isDisabled ? Color.rbTextTertiary : Color.rbTextSecondary
        case .copied: return Color.rbSuccess
        case .failed: return Color.rbDanger
        }
    }

    private var helpText: String {
        switch copyState {
        case .idle:   return isDisabled ? "Log not yet loaded" : "Copy log to clipboard"
        case .copied: return "Copied to clipboard"
        case .failed: return "Log not available — try again once the log has loaded"
        }
    }

    // MARK: - Action

    /// Calls `fetch`, writes the result to the pasteboard on success,
    /// or briefly shows a red \"Failed\" state if the text is nil/empty.
    private func performCopy() {
        fetch { text in
            DispatchQueue.main.async {
                if let text, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copyState = .copied
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copyState = .idle
                    }
                } else {
                    copyState = .failed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copyState = .idle
                    }
                }
            }
        }
    }
}
