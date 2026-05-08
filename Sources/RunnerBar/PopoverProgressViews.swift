import SwiftUI

// MARK: - PieProgressDot

/// Small pie/radial fill indicator that replaces the plain `Circle` dot on action
/// and job rows. Sized to match the existing 8 pt dot footprint so layout is unchanged.
///
/// - `progress`: 0.0–1.0 fill fraction. Pass `nil` for an indeterminate ring.
/// - `color`: fill and stroke color — matches existing green/yellow/blue/red/gray semantics.
struct PieProgressDot: View {
    /// Radial fill fraction (0.0–1.0). Nil renders a plain unfilled ring.
    let progress: Double?
    /// Fill and stroke colour.
    let color: Color
    /// Dot diameter; defaults to 8 to match existing action-row dots.
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(color.opacity(0.25), lineWidth: 1.5)
                .frame(width: size, height: size)
            // Filled pie slice
            if let fraction = progress, fraction > 0 {
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
            } else if progress == nil {
                // Indeterminate: full solid dot
                Circle().fill(color).frame(width: size * 0.55, height: size * 0.55)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - RelativeTimeFormatter

/// Formats a `Date` into a compact relative string like `"3m ago"`, `"1h ago"`, `"2d ago"`.
///
/// Intended for one-off formatting in row views; not observation-based —
/// callers should refresh on a suitable timer tick (e.g. every 60 s).
enum RelativeTimeFormatter {
    /// Returns a short relative string for the interval between `date` and `now`.
    /// - Returns `"just now"` for intervals < 60 s.
    /// - Returns `"Nm ago"` for intervals < 60 min.
    /// - Returns `"Nh ago"` for intervals < 48 h.
    /// - Returns `"Nd ago"` for longer intervals.
    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return "just now"
        case ..<3_600:
            return "\(Int(seconds / 60))m ago"
        case ..<172_800:
            return "\(Int(seconds / 3_600))h ago"
        default:
            return "\(Int(seconds / 86_400))d ago"
        }
    }
}
