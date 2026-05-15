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
