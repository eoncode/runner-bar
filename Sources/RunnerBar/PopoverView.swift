// swiftlint:disable all
import SwiftUI

/// Root popover view — delegates to PopoverMainView which wires callbacks
/// from the NavigationCallbacks environment object.
struct PopoverView: View {
    @EnvironmentObject var store: RunnerStoreObservable
    @EnvironmentObject var callbacks: NavigationCallbacks

    var body: some View {
        PopoverMainView()
    }
}
