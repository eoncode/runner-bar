// swiftlint:disable all
// force-v3
import SwiftUI

struct CancelButton: View {
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
