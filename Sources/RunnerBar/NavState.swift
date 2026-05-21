// MARK: - NavState
//
// Represents the currently visible navigation screen inside the RunnerBar panel.
//
// Extracted from AppDelegate.swift (#602) — was a private enum co-located with
// AppDelegate. Moved here so navigation cases can be extended without opening
// AppDelegate.
//
// #455: Removed .jobDetail, .actionDetail, .actionJobDetail, .actionStepLog.
// Navigation from the main view now goes directly: inline step tap → .stepLog.

/// Represents the currently visible navigation screen.
enum NavState {
    /// The root popover showing runners and the recent-actions list.
    case main
    /// The raw log for a single step, reached from the main inline step row.
    case stepLog(ActiveJob, JobStep)
    /// The Settings sheet.
    case settings
    /// Runner detail drill-down reached from SettingsView runner row tap. (#491)
    case runnerDetail(RunnerModel)
    /// Scope detail drill-down reached from SettingsView scope row tap. (#499)
    case scopeDetail(ScopeEntry)
}
