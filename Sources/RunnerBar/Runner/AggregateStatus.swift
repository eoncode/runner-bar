// MARK: - AggregateStatus

enum AggregateStatus {
    case allOnline
    case someOffline
    case allOffline

    var dot: String {
        switch self {
        case .allOnline:  return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }

    var symbolName: String {
        switch self {
        case .allOnline:  return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
        }
    }
}
