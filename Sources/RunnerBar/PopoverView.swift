// swiftlint:disable all
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: RunnerStoreObservable
    @EnvironmentObject var callbacks: NavigationCallbacks

    var body: some View {
        PopoverMainViewSubviews(
            onSelectJob: callbacks.onSelectJob,
            onSelectAction: callbacks.onSelectAction,
            onSelectSettings: callbacks.onSelectSettings,
            onSelectInlineJob: callbacks.onSelectInlineJob
        )
    }
}
