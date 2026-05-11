import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// HeightReporter — lets SwiftUI views push their rendered height to AppDelegate
//
// IMPORTANT: uses .overlay (not .background) for the GeometryReader.
// A GeometryReader in .background greedily expands to fill available space
// and collapses the parent VStack on first render — causing the header to
// vanish. .overlay reads the already-computed frame without affecting layout.
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
    /// Uses .overlay so the GeometryReader reads the settled frame
    /// without interfering with the VStack layout.
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
