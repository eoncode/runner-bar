// swiftlint:disable missing_docs sorted_imports
import SwiftUI

// MARK: - CancelButton
struct CancelButton: View {
    let group: ActionGroup
    @EnvironmentObject var store: RunnerStoreObservable
    @State private var phase: ButtonPhase = .idle

    var body: some View {
        ButtonPhaseView(
            phase: phase,
            idleLabel: "Cancel",
            idleIcon: "xmark.circle"
        ) {
            Task {
                phase = .loading
                do {
                    try await store.cancelWorkflow(group: group)
                    phase = .success
                } catch {
                    phase = .failure
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                phase = .idle
            }
        }
    }
}
// swiftlint:enable missing_docs sorted_imports
