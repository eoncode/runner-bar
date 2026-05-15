// swiftlint:disable missing_docs
import SwiftUI

struct ReRunButton: View {
    let action: (@escaping (Bool) -> Void) -> Void
    let isDisabled: Bool
    @State private var phase: ButtonPhase = .idle

    var body: some View {
        ButtonPhaseView(
            phase: phase,
            idleLabel: "Re-run",
            idleIcon: "arrow.clockwise"
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
// swiftlint:enable missing_docs
