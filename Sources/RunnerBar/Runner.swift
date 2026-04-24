import Foundation

struct Runner: Codable, Identifiable {
    let id: Int
    let name: String
    let status: String  // "online" or "offline"
    let busy: Bool

    var busyCount: Int = 1

    enum CodingKeys: String, CodingKey {
        case id, name, status, busy
    }

    var displayStatus: String {
        if status == "offline" { return "offline" }
        // fetchMetrics now does a per-runner ps aux match — no busyCount averaging
        let m = fetchMetrics(for: name)
        let cpu = m.map { String(format: "%.1f", $0.cpu) } ?? "0"
        let mem = m.map { String(format: "%.1f", $0.mem) } ?? "0"
        let label = busy ? "active" : "idle"
        return "\(label) (CPU: \(cpu)% MEM: \(mem)%)"
    }
}
