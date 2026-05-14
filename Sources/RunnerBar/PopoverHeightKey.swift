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

// Retained for source compatibility. Not used in the current NSPanel architecture.
struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
