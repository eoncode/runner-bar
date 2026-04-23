import Foundation

struct Runner: Codable, Identifiable {
    let id: Int
    let name: String
    let status: String  // "online" or "offline"
    let busy: Bool

    var displayStatus: String {
        if status == "offline" { return "offline" }
        return busy ? "active" : "idle"
    }
}

private struct RunnersResponse: Codable {
    let runners: [Runner]
}
