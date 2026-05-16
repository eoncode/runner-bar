import SwiftUI

/// Root view for the main popover panel.
///
/// Navigation callbacks are provided by `NavigationCallbacks` (injected by AppDelegate via
/// `wrapEnv`) so this view needs no init parameters.
struct PopoverMainView: View {
    @EnvironmentObject private var callbacks: NavigationCallbacks

    var body: some View {
        PopoverMainViewSubviews(
            onSelectJob: callbacks.onSelectJob,
            onSelectAction: callbacks.onSelectAction,
            onSelectSettings: callbacks.onSelectSettings,
            onSelectInlineJob: callbacks.onSelectInlineJob
        )
    }
}
