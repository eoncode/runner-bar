// swiftlint:disable all
import Foundation

struct Runner: Identifiable, Codable, Equatable {
    let id: Int
    let name: String
    let status: String
    let busy: Bool
    let labels: [RunnerLabel]
    var isLocalRunner: Bool? = nil
}

struct RunnerLabel: Codable, Equatable {
    let name: String
}

struct JobStep: Identifiable, Equatable {
    let id: Int
    let name: String?
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    var number: Int { id }
    var elapsed: String {
        guard let start = startedAt else { return "" }
        let end = completedAt ?? Date()
        let sec = Int(end.timeIntervalSince(start))
        guard sec >= 0 else { return "0s" }
        return sec >= 60 ? String(format: "%dm%02ds", sec / 60, sec % 60) : "\(sec)s"
    }
}
