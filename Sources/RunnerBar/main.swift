import AppKit

// swiftlint:disable missing_docs
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
// swiftlint:enable missing_docs
