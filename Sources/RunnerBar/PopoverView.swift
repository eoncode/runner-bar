import SwiftUI

// MARK: - PopoverView
/// Root view injected into the status-bar popover.
/// Resolves the active navigation destination and renders the correct child view.
struct PopoverView: View {
    /// The shared runner-store observable that drives all child views.
    @EnvironmentObject var store: RunnerStoreObservable

    var body: some View {
        PopoverRootView()
            .environmentObject(store)
    }
}
