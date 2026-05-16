// swiftlint:disable file_header
import AppKit

// MARK: - Entry point

/// Entry point: instantiates `AppDelegate` and starts the run loop.
/// Wrapped in `MainActor.assumeIsolated` because `AppDelegate` is `@MainActor`-isolated.
/// The OS always starts execution on the main thread so this assertion is always valid.
/// ❌ NEVER remove this wrapper — it prevents a strict-concurrency build error.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
// swiftlint:enable file_header
