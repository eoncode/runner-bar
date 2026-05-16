// swiftlint:disable all
import Foundation

/// Environment object that carries AppDelegate-owned navigation closures into
/// the SwiftUI view hierarchy.
///
/// PopoverMainView reads this via @EnvironmentObject so it can trigger navigation
/// without needing init-time callback parameters.
final class NavigationCallbacks: ObservableObject {
    let onSelectJob: (ActiveJob) -> Void
    let onSelectAction: (ActionGroup) -> Void
    let onSelectSettings: () -> Void
    let onSelectInlineJob: (ActiveJob, ActionGroup) -> Void

    init(
        onSelectJob: @escaping (ActiveJob) -> Void,
        onSelectAction: @escaping (ActionGroup) -> Void,
        onSelectSettings: @escaping () -> Void,
        onSelectInlineJob: @escaping (ActiveJob, ActionGroup) -> Void
    ) {
        self.onSelectJob        = onSelectJob
        self.onSelectAction     = onSelectAction
        self.onSelectSettings   = onSelectSettings
        self.onSelectInlineJob  = onSelectInlineJob
    }
}
