import SwiftUI

// MARK: - PieProgressDot

/// Small pie/radial fill indicator that replaces the plain `Circle` dot on action
/// and job rows. Sized to match the existing 8 pt dot footprint so layout is unchanged.
///
/// - `progress`: 0.0–1.0 fill fraction for a filled wedge. Pass `nil` for an indeterminate ring.
/// - `color`: fill colour — matches existing green/yellow/blue/red/gray semantics.
struct PieProgressDot: View {
    /// Radial fill fraction (0.0–1.0). Nil renders a thin unfilled ring (indeterminate).
    let progress: Double?
    /// Wedge fill and ring stroke colour.
    let color: Color
    /// Dot diameter; defaults to 8 to match existing action-row dots.
    var size: CGFloat = 8

    /// Renders a filled pie-wedge, indeterminate ring, or empty ring depending on `progress`.
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side / 2
            ZStack {
                // Background ring
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 1)
                    .frame(width: side, height: side)
                if let fraction = progress {
                    if fraction >= 1 {
                        // Full fill
                        Circle().fill(color).frame(width: side, height: side)
                    } else if fraction > 0 {
                        // Filled wedge from -90° sweeping clockwise
                        Path { path in
                            path.move(to: center)
                            path.addArc(
                                center: center,
                                radius: radius,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(-90 + fraction * 360),
                                clockwise: false
                            )
                            path.closeSubpath()
                        }
                        .fill(color)
                    }
                    // fraction == 0: only the background ring shows
                } else {
                    // Indeterminate: small filled centre dot
                    Circle()
                        .fill(color)
                        .frame(width: side * 0.5, height: side * 0.5)
                        .position(center)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - RelativeTimeFormatter

/// Formats a `Date` into a compact relative string like `"3m ago"`, `"1h ago"`, `"2d ago"`.
///
/// Intended for one-off formatting in row views; not observation-based —
/// callers should refresh on a suitable timer tick.
enum RelativeTimeFormatter {
    /// Returns a short relative string for the interval between `date` and `now`.
    /// Returns `"just now"` for intervals < 60 s, `"Nm ago"` < 60 min,
    /// `"Nh ago"` < 48 h, and `"Nd ago"` otherwise.
    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:      return "just now"
        case ..<3_600:   return "\(Int(seconds / 60))m ago"
        case ..<172_800: return "\(Int(seconds / 3_600))h ago"
        default:         return "\(Int(seconds / 86_400))d ago"
        }
    }
}

// MARK: - ActionGroup + progressFraction

/// Adds a pie-progress fraction property to `ActionGroup` for use with `PieProgressDot`.
extension ActionGroup {
    /// Radial fill fraction (0.0–1.0). Returns `nil` while queued or when no jobs are available.
    var progressFraction: Double? {
        switch groupStatus {
        case .queued:
            return nil
        case .completed:
            return 1.0
        case .inProgress:
            guard jobsTotal > 0 else { return nil }
            return Double(jobsDone) / Double(jobsTotal)
        }
    }
}

// MARK: - ActiveJob + progressFraction

/// Adds a pie-progress fraction property to `ActiveJob` for use with `PieProgressDot`.
extension ActiveJob {
    /// Radial fill fraction (0.0–1.0). Returns `nil` while queued or when no steps are available.
    var progressFraction: Double? {
        switch status {
        case "queued":
            return nil
        case "completed":
            return 1.0
        default:
            guard !steps.isEmpty else { return nil }
            let done = steps.filter { $0.conclusion != nil }.count
            return Double(done) / Double(steps.count)
        }
    }
}
