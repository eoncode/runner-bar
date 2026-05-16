// swiftlint:disable all
import Foundation

struct Runner: Identifiable, Equatable {
    let id: String          // bridged from GitHub's Int id — String breaks ForEach(Range<Int>) overload
    let name: String
    let status: String
    let busy: Bool
    let labels: [RunnerLabel]
    var isLocalRunner: Bool? = nil
    var metrics: RunnerMetrics? = nil
}

extension Runner: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, busy, labels, isLocalRunner, metrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // GitHub returns id as an integer; store as String so Runner.ID != Int
        // and ForEach cannot confuse [Runner] with Range<Int>.
        if let intId = try? c.decode(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name          = try c.decode(String.self,         forKey: .name)
        status        = try c.decode(String.self,         forKey: .status)
        busy          = try c.decode(Bool.self,           forKey: .busy)
        labels        = try c.decode([RunnerLabel].self,  forKey: .labels)
        isLocalRunner = try c.decodeIfPresent(Bool.self,  forKey: .isLocalRunner)
        metrics       = try c.decodeIfPresent(RunnerMetrics.self, forKey: .metrics)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,            forKey: .id)
        try c.encode(name,          forKey: .name)
        try c.encode(status,        forKey: .status)
        try c.encode(busy,          forKey: .busy)
        try c.encode(labels,        forKey: .labels)
        try c.encodeIfPresent(isLocalRunner, forKey: .isLocalRunner)
        try c.encodeIfPresent(metrics,       forKey: .metrics)
    }
}

struct RunnerLabel: Codable, Equatable {
    let name: String
}
