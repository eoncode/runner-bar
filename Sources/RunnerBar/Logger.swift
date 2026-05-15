// swiftlint:disable all
import Foundation

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[RunnerBar \(ts)] \(message)")
}
