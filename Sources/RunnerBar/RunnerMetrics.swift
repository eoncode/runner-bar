import Foundation

/// Aggregated runner health metrics for a single scope.
struct RunnerMetrics {
    /// Number of runners currently online.
    let online: Int
    /// Number of runners currently offline.
    let offline: Int
    /// Total runner count (online + offline).
    var total: Int { online + offline }
}

/// Fetches runner metrics for all configured scopes.
///
/// Iterates `ScopeStore.shared.scopes` and returns one `RunnerMetrics` per scope.
func allWorkerMetrics() -> [RunnerMetrics] {
    ScopeStore.shared.scopes.compactMap { scope -> RunnerMetrics? in
        guard let data = ghAPI("repos/\(scope)/actions/runners"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runners = json["runners"] as? [[String: Any]] else { return nil }
        let online = runners.filter { ($0["status"] as? String) == "online" }.count
        return RunnerMetrics(online: online, offline: runners.count - online)
    }
}
