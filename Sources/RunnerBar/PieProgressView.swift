import SwiftUI

// MARK: - PieProgressView

/// A small circular progress indicator that renders as a radial pie fill.
///
/// Visual states:
/// - `progress == nil`       → indeterminate: small filled centre dot (e.g. queued jobs)
/// - `progress == 0.0`       → empty circle outline only
/// - `0.0 < progress < 1.0`  → partial filled wedge from 12 o'clock clockwise (◔ ◑ ◕)
/// - `progress >= 1.0`       → solid filled circle (●), no outline ring
///
/// Used in action rows (size: 8) and inline ↳ child job rows (size: 7).
struct PieProgressView: View {
    /// Completion fraction from 0.0 to 1.0, or `nil` for an indeterminate state.
    /// Use `nil` for queued / no-step-data states — semantically cleaner than `0.5`.
    let progress: Double?
    /// Status-driven color (green / yellow / red / gray).
    let color: Color
    /// Diameter in points. Defaults to 8 (main action row size).
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            if let progress = progress {
                if progress >= 1.0 {
                    // Full fill — no outline ring so there is no halo (fix #6 / #314)
                    Circle().fill(color)
                } else {
                    // Background ring — only shown when not fully complete
                    Circle()
                        .stroke(color.opacity(0.25), lineWidth: size * 0.25)
                    if progress > 0 {
                        // Filled pie wedge via Path (fix #5 / #314)
                        GeometryReader { geo in
                            let radius = geo.size.width / 2
                            let center = CGPoint(x: radius, y: radius)
                            let start = Angle.degrees(-90)
                            let end   = Angle.degrees(-90 + 360 * progress)
                            Path { path in
                                path.move(to: center)
                                path.addArc(
                                    center: center,
                                    radius: radius,
                                    startAngle: start,
                                    endAngle: end,
                                    clockwise: false
                                )
                                path.closeSubpath()
                            }
                            .fill(color)
                        }
                    }
                }
            } else {
                // Indeterminate state: background ring + small filled centre dot.
                // Shown for queued jobs or when no step data is available.
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: size * 0.25)
                Circle()
                    .fill(color)
                    .frame(width: size * 0.4, height: size * 0.4)
            }
        }
        .frame(width: size, height: size)
    }
}
