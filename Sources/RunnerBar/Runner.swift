import Foundation

struct Runner: Codable, Identifiable {
    let id: Int
    let name: String
    let status: String  // "online" or "offline"
    let busy: Bool

    // Assigned after fetch by RunnerStore, not decoded from JSON
    var metrics: RunnerMetrics? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, status, busy
    }

    var displayStatus: String {
        if status == "offline" { return "offline" }
        let label = busy ? "active" : "idle"
        guard let m = metrics else {
            return "\(label) (CPU: — MEM: —)"
        }
        let cpu = String(format: "%.1f", m.cpu)
        let mem = String(format: "%.1f", m.mem)
        return "\(label) (CPU: \(cpu)% MEM: \(mem)%)"
    }
}
