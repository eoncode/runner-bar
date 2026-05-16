import AppKit

// MARK: - Entry point

// swiftlint:disable:next function_parameter_count
MainActor.assumeIsolated {
    // swiftlint:disable:next cyclomatic_complexity
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
