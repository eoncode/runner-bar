// WorkflowProgressExtensions.swift
// RunnerBar
// Extracted from PanelProgressViews.swift during dead-code cleanup (removed PieProgressDot).
import Foundation
import RunnerBarCore

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

// MARK: - WorkflowActionGroup + progressFraction
/// Adds a pie-progress fraction property to `WorkflowActionGroup` for use with `DonutStatusView`.
extension WorkflowActionGroup {
    /// Radial fill fraction (0.0–1.0). Returns `nil` while queued or when no jobs are available.
    var progressFraction: Double? {
        switch groupStatus {
        case .queued: return nil
        case .completed: return 1.0
        case .inProgress:
            guard jobsTotal > 0 else { return nil }
            let fraction = Double(jobsDone) / Double(jobsTotal)
            return min(max(fraction, 0.0), 1.0)
        }
    }
}

// MARK: - ActiveJob + progressFraction
/// Adds a pie-progress fraction property to `ActiveJob` for use with `DonutStatusView`.
extension ActiveJob {
    /// Radial fill fraction (0.0–1.0). Returns `nil` while queued or when no steps are available.
    var progressFraction: Double? {
        switch status {
        case "queued": return nil
        case "completed": return 1.0
        default:
            guard !steps.isEmpty else { return nil }
            let done = steps.filter { $0.conclusion != nil }.count
            let fraction = Double(done) / Double(steps.count)
            return min(max(fraction, 0.0), 1.0)
        }
    }
}
