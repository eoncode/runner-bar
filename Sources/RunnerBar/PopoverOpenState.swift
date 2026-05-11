import SwiftUI

// MARK: - PopoverOpenState

/// Observable open/closed state of the popover, injected as an @EnvironmentObject
/// into the view hierarchy from AppDelegate.mainView().
///
/// This is the ONLY correct way to communicate popover open state to views deep
/// in the nav tree (e.g. InlineJobRowsView). A plain `Bool` prop is frozen at
/// construction time and will always read `false` because mainView() is constructed
/// before openPopover() sets popoverIsOpen = true.
///
/// ❌ NEVER replace this with a plain `var isPopoverOpen: Bool` prop on views
///    that need live open-state during the popover show/hide lifecycle.
/// ❌ NEVER add a second instance of this class — AppDelegate owns the single instance.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
/// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
/// is major major major.
final class PopoverOpenState: ObservableObject {
    @Published var isOpen: Bool = false
}
