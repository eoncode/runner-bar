import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// HeightReporter — lets SwiftUI views push their rendered height to AppDelegate
//
// Usage: add .reportHeight(to: appDelegate) on any root view.
// AppDelegate implements HeightReceiver and calls panel.updateHeight().
// ─────────────────────────────────────────────────────────────────────────────

struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

protocol HeightReceiver: AnyObject {
    func didUpdateHeight(_ height: CGFloat)
}

extension View {
    /// Measures the view's rendered height and reports it to `receiver`.
    func reportHeight(to receiver: HeightReceiver) -> some View {
        self
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: HeightPreferenceKey.self,
                                    value: geo.size.height)
                }
            )
            .onPreferenceChange(HeightPreferenceKey.self) { h in
                if h > 0 { receiver.didUpdateHeight(h) }
            }
    }
}
