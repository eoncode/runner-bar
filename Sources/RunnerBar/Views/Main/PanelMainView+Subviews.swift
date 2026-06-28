// PanelMainView+Subviews.swift
// RunBot

// Retains only shared glue after extracting focused view files:
//   - PanelHeaderView.swift  (PanelHeaderView, SectionHeaderLabel)
//   - RunnerRowViews.swift   (PanelLocalRunnerRow, RunnerMetricsBadge, RunnerTypeIcon)
//   - ActionRowView.swift    (ActionRowView, RowTapModifier)

import RunBotCore
import SwiftUI

// MARK: - String+nilIfEmpty
/// Convenience helpers used across panel subview files.
extension String {
    /// Returns `nil` when the string is empty, otherwise returns `self`.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
