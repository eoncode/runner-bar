import SwiftUI

// MARK: - PieProgressView

/// A small circular progress indicator that renders as a radial pie fill.
///
/// Visual states:
/// - `progress == 0.0` → empty circle outline only
/// - `0.0 < progress < 1.0` → partial arc from 12 o'clock clockwise (◔ ◑ ◕)
/// - `progress == 1.0` → solid filled circle (●)
///
/// Used in action rows (size: 8) and inline ↳ child job rows (size: 7).
struct PieProgressView: View {
    /// Completion fraction from 0.0 to 1.0.
    let progress: Double
    /// Status-driven color (green / yellow / red / gray).
    let color: Color
    /// Diameter in points. Defaults to 8 (main action row size).
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: size * 0.25)
            if progress >= 1.0 {
                Circle().fill(color)
            } else if progress > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .rotation(.degrees(-90))
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.25, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}
