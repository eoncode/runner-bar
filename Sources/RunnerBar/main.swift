// swiftlint:disable missing_docs
import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
// swiftlint:enable missing_docs
