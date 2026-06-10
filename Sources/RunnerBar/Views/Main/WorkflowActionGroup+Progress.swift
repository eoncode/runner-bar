// WorkflowActionGroup+Progress.swift
// RunnerBar
// Extracted from PanelProgressViews.swift during dead-code cleanup (removed PieProgressDot).
import Foundation
import RunnerBarCore
import SwiftUI

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

// MARK: - WorkflowActionGroup progress helpers

/// UI-layer extensions on `WorkflowActionGroup` for deriving progress fractions
/// and display strings used by the panel's action rows.
extension WorkflowActionGroup {

    /// Returns the overall completion fraction (0.0–1.0) across all jobs in the group.
    ///
    /// Calculated as the ratio of completed steps to total steps. Returns `nil`
    /// when no steps are present so callers can suppress progress indicators entirely.
    var progressFraction: Double? {
        let steps = jobs.flatMap { $0.steps }
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { $0.conclusion != nil || $0.status == .completed }.count
        return Double(done) / Double(steps.count)
    }

    /// A formatted string showing completed vs total job count, e.g. `"2/4"`.
    ///
    /// Returns an empty string when the group has no jobs.
    var jobProgress: String {
        guard !jobs.isEmpty else { return "" }
        let done = jobs.filter { $0.conclusion != nil }.count
        return "\(done)/\(jobs.count)"
    }

    /// Elapsed time as a `mm:ss` string, computed from `firstJobStartedAt` to
    /// `lastJobCompletedAt` (completed runs) or `Date()` (active runs).
    ///
    /// Returns an empty string when no job has started yet.
    /// Use `RelativeTimeFormatter.string(from: firstJobStartedAt)` for the time-ago display.
    var elapsed: String {
        guard let start = firstJobStartedAt else { return "" }
        let end = lastJobCompletedAt ?? Date()
        let sec = max(0, Int(end.timeIntervalSince(start)))
        let mins = sec / 60
        let secs = sec % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    /// The start date of the earliest job in the group, or `nil` if none has started.
    var firstJobStartedAt: Date? {
        jobs.compactMap { $0.startedAt }.min()
    }

    /// `true` when the group is completed and its conclusion is neither success nor failure.
    var isDimmed: Bool {
        guard groupStatus == .completed else { return false }
        return conclusion != "success" && conclusion != "failure"
    }

    /// `true` when the group originated from a self-hosted (local) runner.
    ///
    /// Derived from the first job's runner name; returns `nil` when ambiguous.
    var isLocalGroup: Bool? {
        guard let first = jobs.first else { return nil }
        return first.runnerName?.lowercased().contains("self-hosted") == true
    }

    /// The short repo name (without owner prefix), e.g. `"runner-bar"` from `"eoncode/runner-bar"`.
    /// Falls back to the full `repo` string when no slash is present.
    var repoShortName: String {
        repo.components(separatedBy: "/").last ?? repo
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
