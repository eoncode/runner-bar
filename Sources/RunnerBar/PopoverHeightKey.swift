import SwiftUI

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️ PopoverHeightKey — DYNAMIC HEIGHT PREFERENCE KEY (ref #377 #375 #376)
// ════════════════════════════════════════════════════════════════════════════════
//
// NOTE: This file is retained for source compatibility but PopoverHeightKey is
// not used in the current NSPanel architecture. Dynamic height is driven by
// KVO on NSHostingController.preferredContentSize (see AppDelegate).
//
// ════════════════════════════════════════════════════════════════════════════════

/// Propagates the total rendered height of the popover content view.
struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
