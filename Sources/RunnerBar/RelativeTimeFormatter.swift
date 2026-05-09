import Foundation

// MARK: - RelativeTimeFormatter

/// Converts a past `Date` into a short human-readable relative string.
///
/// The `relativeTo` parameter defaults to `Date()` (now) but is overridable
/// in unit tests to avoid mocking the system clock.
///
/// Examples:
/// - 30 seconds ago  → `"just now"`
/// - 3 minutes ago   → `"3m ago"`
/// - 2 hours ago     → `"2h ago"`
/// - 3 days ago      → `"3d ago"`
enum RelativeTimeFormatter {
    /// Returns a short relative-time string for `date` measured against `now`.
    ///
    /// - Parameters:
    ///   - date: The reference point in the past.
    ///   - now: The current time. Defaults to `Date()`. Override in tests.
    /// - Returns: A short human-readable string, or `"—"` if `date` is in the future.
    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "—" }
        switch seconds {
        case ..<60:       return "just now"
        case ..<3_600:    return "\(Int(seconds / 60))m ago"
        case ..<172_800:  return "\(Int(seconds / 3_600))h ago"
        default:          return "\(Int(seconds / 86_400))d ago"
        }
    }
}
