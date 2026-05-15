// swiftlint:disable missing_docs sorted_imports
import SwiftUI

// MARK: - CancelButton

/// A button that cancels all runs for an action group.
/// Uses a closure-based action so callers control the async work.
struct CancelButton: View {
    /// Called when tapped. Caller invokes the completion with `true` on success.
    let action: (@escaping (Bool) -> Void) -> Void
    let isDisabled: Bool
    @State private var phase: ButtonPhase = .idle

    var body: some View {
        ButtonPhaseView(
            phase: phase,
            idleLabel: "Cancel",
            idleIcon: "xmark.circle"
        ) {
            guard !isDisabled else { return }
            phase = .loading
            action { succeeded in
                phase = succeeded ? .success : .failure
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { phase = .idle }
            }
        }
        .disabled(isDisabled)
    }
}
// swiftlint:enable missing_docs sorted_imports
