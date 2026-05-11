import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️  PopoverOpenState — SIDE-JUMP REGRESSION GUARD  ⚠️
// ════════════════════════════════════════════════════════════════════════════════
//
// PURPOSE:
//   Provides a live, mutable signal of whether the NSPopover is currently open.
//   Injected into the view hierarchy as an @EnvironmentObject so that
//   InlineJobRowsView (and any other view) can read the open state without
//   receiving a frozen Bool prop captured at construction time.
//
// WHY NOT A PLAIN Bool PROP:
//   AppDelegate constructs PopoverMainView (via mainView()) BEFORE the popover
//   opens. Any plain `var isPopoverOpen: Bool` prop is therefore always `false`
//   at the point InlineJobRowsView evaluates it. The EnvironmentObject is
//   mutated by AppDelegate immediately before NSPopover.show() and after
//   NSPopover.close(), so the value seen inside InlineJobRowsView is always live.
//
// USAGE:
//   AppDelegate sets popoverOpenState.isOpen = true  before  show()
//               sets popoverOpenState.isOpen = false after   close()
//   Inject via .environmentObject(popoverOpenState) on the root hosting controller view.
//
// ⚠️ SIDE-JUMP CONTRACT (ref #377):
//   InlineJobRowsView gates `cap += 4` behind !popoverOpenState.isOpen.
//   Mutating `cap` while the popover is open causes a height change →
//   preferredContentSize update → NSPopover re-anchors → side-jump.
//   ❌ NEVER mutate any @State that affects fittingSize.height while isOpen == true.
//   ❌ NEVER replace this with a plain Bool prop.
//   ❌ NEVER remove .disabled(popoverOpenState.isOpen) from InlineJobRowsView's expand button.
//   If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT
//   ALLOWED UNDER ANY CIRCUMSTANCE. The regression we get when this comment
//   is removed is major major major.
//
// ════════════════════════════════════════════════════════════════════════════════

/// Observable wrapper for the NSPopover open/closed state.
///
/// Injected as `@EnvironmentObject` so child views get a live value even though
/// the hosting controller is constructed before the popover is shown.
final class PopoverOpenState: ObservableObject {
    /// `true` from immediately before `NSPopover.show()` until after `NSPopover.close()`.
    /// ❌ NEVER read this from a captured closure in AppDelegate — always read from
    ///   the @EnvironmentObject inside the view.
    @Published var isOpen: Bool = false
}
