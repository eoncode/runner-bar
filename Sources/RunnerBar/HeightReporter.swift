import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// HeightReporter — SwiftUI views push their rendered height to AppDelegate
//
// IMPORTANT: uses .overlay (not .background) for the GeometryReader.
// A GeometryReader in .background greedily expands and collapses the
// parent VStack on first render. .overlay reads the already-settled
// frame without affecting layout.
//
// Usage: add .reportHeight(to: self) in each AppDelegate view factory.
// AppDelegate conforms to HeightReceiver and updates popover.contentSize.
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
    /// Measures rendered height and reports it to `receiver` without
    /// affecting layout (overlay, not background).
    func reportHeight(to receiver: HeightReceiver) -> some View {
        self
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: HeightPreferenceKey.self,
                                    value: geo.size.height)
                }
            )
            .onPreferenceChange(HeightPreferenceKey.self) { h in
                DispatchQueue.main.async {
                    if h > 0 { receiver.didUpdateHeight(h) }
                }
            }
    }
}
