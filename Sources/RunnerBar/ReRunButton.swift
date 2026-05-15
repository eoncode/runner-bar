import SwiftUI

// MARK: - ReRunButton
/// Triggers a full re-run of a completed workflow run via the GitHub API.
struct ReRunButton: View {
    /// The action group to re-run.
    let group: ActionGroup
    /// Shared runner store used to dispatch the re-run API call.
    @EnvironmentObject var store: RunnerStoreObservable
    /// Phase animation state for the button label.
    @State private var phase: ButtonPhase = .idle

    var body: some View {
        ButtonPhaseView(
            phase: phase,
            idleLabel: "Re-run all",
            idleIcon: "arrow.clockwise"
        ) {
            Task {
                phase = .loading
                do {
                    try await store.reRunWorkflow(group: group)
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
