import Foundation

struct Runner: Codable, Identifiable {
    let id: Int
    let name: String
    let status: String  // "online" or "offline"
    let busy: Bool

    // Populated post-fetch by RunnerStore, not from API
    var busyCount: Int = 1

    enum CodingKeys: String, CodingKey {
        case id, name, status, busy
    }

    var displayStatus: String {
        if status == "offline" { return "offline" }
        if busy {
            if let m = fetchMetrics(for: name, busyCount: busyCount) {
                return "active (CPU: \(m.cpu)% MEM: \(m.mem)%)"
            }
            return "active"
        }
        return "idle"
    }
}

private struct RunnersResponse: Codable {
    let runners: [Runner]
}
