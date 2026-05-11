import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️ PopoverHeightKey — DYNAMIC HEIGHT PREFERENCE KEY (ref #377 #375 #376)
// ════════════════════════════════════════════════════════════════════════════════
//
// PURPOSE:
// Propagates the rendered height of PopoverMainView up to AppDelegate so that
// NSPopover.setContentSize() can be called ONCE after the first real layout pass.
//
// HOW IT WORKS:
// 1. PopoverMainView wraps its root VStack in .background(GeometryReader { ... })
// 2. GeometryReader writes geo.size.height into PopoverHeightKey via .preference()
// 3. The root view reads .onPreferenceChange(PopoverHeightKey.self) and calls
//    popoverOpenState.reportHeight(height) — a callback set by AppDelegate.
// 4. AppDelegate.openPopover() sets popoverOpenState.onHeightReady BEFORE show(),
//    which calls popover.setContentSize() on main thread. animates=false = no jump.
//
// WHY NOT sizingOptions=.preferredContentSize:
// That causes NSPopover to re-anchor on every SwiftUI state update → side-jump.
// We use sizingOptions=[] and call setContentSize ONCE per open.
//
// WHY NOT fittingSize BEFORE show():
// RunnerStoreObservable.reload() is sync but data arrives async. fittingSize
// measured before data arrives always returns near-zero → 300pt fallback.
//
// ⚠️ REDUCTION RULE:
// .onPreferenceChange fires on EVERY layout pass. The callback must only call
// setContentSize once per open (guarded by popoverOpenState.heightReported flag).
// ❌ NEVER call setContentSize on every preference change — it causes repeated
//    resize events → side-jump.
// ❌ NEVER remove this file.
// ❌ NEVER rename PopoverHeightKey.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
// ════════════════════════════════════════════════════════════════════════════════

/// Propagates the total rendered height of the popover content view.
struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
