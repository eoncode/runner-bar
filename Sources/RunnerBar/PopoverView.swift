import SwiftUI

// MARK: - PopoverOpenState

/// Observable object that tracks whether the popover panel is currently visible.
/// Injected into the SwiftUI environment via `AppDelegate.wrapEnv(_:)`.
final class PopoverOpenState: ObservableObject {
    /// `true` while the NSPanel is on screen.
    @Published var isOpen: Bool = false
}
