import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️ PopoverOpenState — SIDE-JUMP REGRESSION GUARD (ref #377 #375 #376)
// ════════════════════════════════════════════════════════════════════════════════
//
// PURPOSE:
// 1. Provides a live, mutable signal of whether the NSPopover is currently open.
// 2. Carries a one-shot height-ready callback used by the GeometryReader/PreferenceKey
//    dynamic height solution (Architecture 3).
//
// WHY NOT A PLAIN Bool PROP:
// AppDelegate constructs PopoverMainView (via mainView()) BEFORE the popover
// opens. Any plain `var isPopoverOpen: Bool` prop is therefore always `false`
// at the point InlineJobRowsView evaluates it. This @EnvironmentObject is
// mutated by AppDelegate immediately before NSPopover.show() and after
// NSPopover.close(), so the value seen inside the view is always live.
//
// HEIGHT CALLBACK (onHeightReady):
// AppDelegate sets onHeightReady BEFORE show(). PopoverMainView calls it ONCE
// via .onPreferenceChange(PopoverHeightKey.self), guarded by heightReported.
// AppDelegate's callback calls popover.setContentSize(). animates=false = no jump.
// After the callback fires, heightReported = true prevents repeated calls.
//
// USAGE:
// AppDelegate:
//   popoverOpenState.isOpen = true
//   popoverOpenState.heightReported = false
//   popoverOpenState.onHeightReady = { [weak popover] h in
//       let w = AppDelegate.fixedWidth
//       let max = self.maxHeight
//       popover?.setContentSize(NSSize(width: w, height: min(h, max)))
//   }
//   popover.show(...)
//
// PopoverMainView:
//   .onPreferenceChange(PopoverHeightKey.self) { h in
//       guard h > 10, !popoverOpenState.heightReported else { return }
//       popoverOpenState.heightReported = true
//       popoverOpenState.onHeightReady?(h)
//   }
//
// ⚠️ CONTRACT:
// ❌ NEVER replace isOpen with a plain Bool prop on any view.
// ❌ NEVER remove onHeightReady or heightReported.
// ❌ NEVER call onHeightReady more than once per open (heightReported guard).
// ❌ NEVER set sizingOptions = .preferredContentSize — that causes side-jump.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
// ════════════════════════════════════════════════════════════════════════════════

/// Observable wrapper for NSPopover open/closed state + one-shot height callback.
final class PopoverOpenState: ObservableObject {
    /// `true` from immediately before `NSPopover.show()` until after `NSPopover.close()`.
    @Published var isOpen: Bool = false

    /// Set to `false` before each `show()`, set to `true` after first height report.
    /// Guards against repeated `setContentSize` calls on every layout pass.
    /// ❌ NEVER remove. ❌ NEVER skip resetting to false before show().
    var heightReported: Bool = false

    /// Called ONCE after the first real rendered height is known.
    /// Set by AppDelegate before show(). Calls popover.setContentSize().
    /// ❌ NEVER call more than once per open.
    var onHeightReady: ((CGFloat) -> Void)?
}
