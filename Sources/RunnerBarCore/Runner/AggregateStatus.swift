// AggregateStatus.swift
// RunnerBar
// MARK: - AggregateStatus

/// Enumerates possible values for AggregateStatus.
public enum AggregateStatus {
    /// The `allOnline` case.
    case allOnline
    /// The `someOffline` case.
    case someOffline
    /// The `allOffline` case.
    case allOffline

    /// The dot property.
    public var dot: String {
        switch self {
        case .allOnline:  return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }

    /// The symbolName property.
    public var symbolName: String {
        switch self {
        case .allOnline:  return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
        }
    }
}
